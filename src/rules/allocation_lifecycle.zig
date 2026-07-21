const std = @import("std");

const syntax_scope = @import("../syntax_scope.zig");
const owned_call = @import("owned_call.zig");
const summaries = @import("summaries.zig");
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
    return warningsWithConfiguration(allocator, source, types.Configuration.defaults());
}

pub fn warningsWithConfiguration(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    configuration: types.Configuration,
) ![]Warning {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);
    var scope_index = try syntax_scope.Index.init(allocator, source, tokens);
    defer scope_index.deinit();
    return warningsWithSyntax(
        allocator,
        source,
        &tree,
        tokens,
        &scope_index,
        configuration,
    );
}

pub fn warningsWithSyntax(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    configuration: types.Configuration,
) ![]Warning {
    const sources = [_]summaries.Source{.{ .file_index = 0, .source = source, .tokens = tokens }};
    var summary_index = try summaries.build(allocator, &sources, configuration);
    defer summary_index.deinit(allocator);
    return warningsWithSummaries(allocator, source, tree, tokens, scope_index, summary_index);
}

pub fn warningsWithSummaries(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    summary_index: summaries.Index,
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
        const statement_end = scope_index.statementEnd(declaration_index) orelse continue;
        const allocation = allocationFromValue(source, tree, tokens, initializer, summary_index) orelse continue;
        const arena_backed = valueReceivesBuildArena(tree, tokens, scope_index, initializer) or if (allocation.allocator_source) |allocator_name|
            std.ascii.indexOfIgnoreCase(allocator_name, "arena") != null or
                allocatorIsArenaBacked(source, tokens, allocator_name) or
                privateAllocatorParameterIsAlwaysArenaBacked(
                    source,
                    tokens,
                    declaration_index,
                    allocator_name,
                    summary_index,
                )
        else
            false;
        const scope_end = scope_index.enclosingScopeEnd(declaration_index) orelse continue;
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
        if (arena_backed) continue;
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
            summary_index,
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
            summary_index,
        );
        if (cleanup == .released or mismatched_release) continue;
        // 'defer pool.deinit(...)' reclaims everything the pool handed out.
        if (allocation.receiver) |receiver_name| {
            if (deferDeinitializesReceiver(source, tokens, scope_index, receiver_name, declaration_index, scope_end)) continue;
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
    try findOverlappingAggregateErrdefers(allocator, source, tokens, scope_index, &found);
    return try found.toOwnedSlice(allocator);
}

fn valueReceivesBuildArena(
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    value: std.zig.Ast.Node.Index,
) bool {
    const call_node = switch (tree.nodeTag(value)) {
        .@"try", .@"nosuspend", .@"comptime" => tree.nodeData(value).node,
        .grouped_expression => tree.nodeData(value).node_and_token[0],
        .@"catch", .@"orelse" => tree.nodeData(value).node_and_node[0],
        else => value,
    };
    var buffer: [1]std.zig.Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, call_node) orelse return false;
    for (call.ast.params) |argument| {
        if (tree.nodeTag(argument) != .identifier) continue;
        const argument_index: usize = tree.nodeMainToken(argument);
        const binding = scope_index.findBinding(argument_index) orelse continue;
        var type_index = binding.token_index + 1;
        if (type_index >= tokens.len or tokens[type_index].tag != .colon) continue;
        type_index += 1;
        while (type_index < tokens.len) : (type_index += 1) {
            switch (tokens[type_index].tag) {
                .comma, .r_paren => break,
                .identifier => if (std.mem.eql(u8, scope_index.source[tokens[type_index].loc.start..tokens[type_index].loc.end], "Build")) return true,
                else => {},
            }
        }
    }
    return false;
}

fn findOverlappingAggregateErrdefers(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    found: *std.ArrayList(Warning),
) !void {
    for (tokens, 0..) |token, equal_index| {
        if (token.tag != .equal or equal_index < 2 or tokens[equal_index - 1].tag != .period_asterisk or
            tokens[equal_index - 2].tag != .identifier) continue;
        const owner_name = source[tokens[equal_index - 2].loc.start..tokens[equal_index - 2].loc.end];
        const owner_binding = scope_index.findBinding(equal_index - 2) orelse continue;
        const owner_type = createdPointerType(source, tokens, scope_index, owner_binding.token_index) orelse continue;
        const assignment_end = scope_index.statementEnd(equal_index) orelse continue;
        const scope = enclosingScope(tokens, equal_index) orelse continue;
        var field_index = equal_index + 1;
        while (field_index + 3 < assignment_end) : (field_index += 1) {
            if (tokens[field_index].tag != .period or tokens[field_index + 1].tag != .identifier or
                tokens[field_index + 2].tag != .equal or tokens[field_index + 3].tag != .identifier) continue;
            const field_name = source[tokens[field_index + 1].loc.start..tokens[field_index + 1].loc.end];
            const binding_name = source[tokens[field_index + 3].loc.start..tokens[field_index + 3].loc.end];
            const field_binding = scope_index.findBinding(field_index + 3) orelse continue;
            if (!typeDeinitReleasesField(source, tokens, scope_index, owner_type, field_name)) continue;
            if (errdeferReleasingBinding(
                source,
                tokens,
                scope_index,
                binding_name,
                field_binding.token_index,
                scope.opening + 1,
                assignment_end,
            ) == null) continue;
            const aggregate_cleanup = errdeferDeinitializingOwner(
                source,
                tokens,
                scope_index,
                owner_name,
                owner_binding.token_index,
                assignment_end + 1,
                scope.closing,
            ) orelse continue;
            try found.append(allocator, .{
                .rule = .double_release,
                .span = tokens[aggregate_cleanup].loc,
                .message = try std.fmt.allocPrint(
                    allocator,
                    "errdefer cleanup for '{s}' releases owned field '{s}' after an earlier errdefer already releases '{s}'",
                    .{ owner_name, field_name, binding_name },
                ),
            });
        }
    }
}

fn createdPointerType(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    owner_binding: usize,
) ?usize {
    if (owner_binding == 0 or
        (tokens[owner_binding - 1].tag != .keyword_const and tokens[owner_binding - 1].tag != .keyword_var) or
        owner_binding + 2 >= tokens.len or tokens[owner_binding + 1].tag != .equal) return null;
    const declaration_end = scope_index.statementEnd(owner_binding - 1) orelse return null;
    for (tokens[owner_binding + 2 .. declaration_end], owner_binding + 2..) |candidate, create_index| {
        if (!tokenIsIdentifier(source, candidate, "create") or create_index + 3 >= declaration_end or
            tokens[create_index + 1].tag != .l_paren or tokens[create_index + 2].tag != .identifier or
            tokens[create_index + 3].tag != .r_paren) continue;
        return create_index + 2;
    }
    return null;
}

fn typeDeinitReleasesField(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    type_use: usize,
    field_name: []const u8,
) bool {
    const type_binding = scope_index.findBinding(type_use) orelse return false;
    const type_name = type_binding.token_index;
    if (type_name == 0 or tokens[type_name - 1].tag != .keyword_const or type_name + 3 >= tokens.len or
        tokens[type_name + 1].tag != .equal or tokens[type_name + 2].tag != .keyword_struct or
        tokens[type_name + 3].tag != .l_brace) return false;
    const type_end = matchingToken(tokens, type_name + 3, .l_brace, .r_brace) orelse return false;
    for (tokens[type_name + 4 .. type_end], type_name + 4..) |candidate, function_index| {
        if (candidate.tag != .keyword_fn or function_index + 3 >= type_end or
            !tokenIsIdentifier(source, tokens[function_index + 1], "deinit") or
            tokens[function_index + 2].tag != .l_paren) continue;
        const parameters_end = matchingToken(tokens, function_index + 2, .l_paren, .r_paren) orelse continue;
        var receiver: ?[]const u8 = null;
        for (tokens[function_index + 3 .. parameters_end], function_index + 3..) |parameter, parameter_index| {
            if (parameter.tag == .identifier and parameter_index + 1 < parameters_end and
                tokens[parameter_index + 1].tag == .colon)
            {
                receiver = source[parameter.loc.start..parameter.loc.end];
                break;
            }
        }
        const receiver_name = receiver orelse continue;
        var body_start = parameters_end + 1;
        while (body_start < type_end and tokens[body_start].tag != .l_brace) : (body_start += 1) {}
        if (body_start == type_end) continue;
        const body_end = matchingToken(tokens, body_start, .l_brace, .r_brace) orelse continue;
        for (tokens[body_start + 1 .. body_end], body_start + 1..) |body_token, method_index| {
            if ((!tokenIsIdentifier(source, body_token, "free") and
                !tokenIsIdentifier(source, body_token, "destroy")) or method_index + 1 >= body_end or
                tokens[method_index + 1].tag != .l_paren) continue;
            const call_end = matchingToken(tokens, method_index + 1, .l_paren, .r_paren) orelse continue;
            var index = method_index + 2;
            while (index + 2 < call_end) : (index += 1) {
                if (tokenIsIdentifier(source, tokens[index], receiver_name) and tokens[index + 1].tag == .period and
                    tokenIsIdentifier(source, tokens[index + 2], field_name)) return true;
            }
        }
    }
    return false;
}

fn errdeferReleasingBinding(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    start: usize,
    end: usize,
) ?usize {
    for (tokens[start..end], start..) |token, defer_index| {
        if (token.tag != .keyword_errdefer) continue;
        const defer_end = scope_index.statementEnd(defer_index) orelse continue;
        if (defer_end >= end) continue;
        var saw_binding = false;
        var saw_release = false;
        var conditional = false;
        for (tokens[defer_index + 1 .. defer_end], defer_index + 1..) |candidate, candidate_index| {
            if (candidate.tag == .keyword_if or candidate.tag == .keyword_switch) conditional = true;
            if (tokenIsIdentifier(source, candidate, binding_name) and
                identifierRefersToBinding(scope_index, binding_index, candidate_index)) saw_binding = true;
            if (tokenIsIdentifier(source, candidate, "free") or tokenIsIdentifier(source, candidate, "destroy")) {
                saw_release = true;
            }
        }
        if (!conditional and saw_binding and saw_release) return defer_index;
    }
    return null;
}

fn errdeferDeinitializingOwner(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    owner_name: []const u8,
    owner_binding: usize,
    start: usize,
    end: usize,
) ?usize {
    for (tokens[start..end], start..) |token, defer_index| {
        if (token.tag != .keyword_errdefer) continue;
        const defer_end = scope_index.statementEnd(defer_index) orelse continue;
        if (defer_end >= end) continue;
        var index = defer_index + 1;
        while (index + 2 < defer_end) : (index += 1) {
            if (tokenIsIdentifier(source, tokens[index], owner_name) and tokens[index + 1].tag == .period and
                identifierRefersToBinding(scope_index, owner_binding, index) and
                tokenIsIdentifier(source, tokens[index + 2], "deinit")) return index + 2;
        }
    }
    return null;
}

const Allocation = struct {
    method: []const u8,
    release: []const u8,
    receiver: ?[]const u8,
    allocator_source: ?[]const u8,
};

fn allocationFromValue(
    source: []const u8,
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
    value: std.zig.Ast.Node.Index,
    summary_index: summaries.Index,
) ?Allocation {
    return switch (tree.nodeTag(value)) {
        .@"try", .@"nosuspend", .@"comptime" => allocationFromValue(source, tree, tokens, tree.nodeData(value).node, summary_index),
        .grouped_expression => allocationFromValue(source, tree, tokens, tree.nodeData(value).node_and_token[0], summary_index),
        .@"catch" => allocationFromValue(source, tree, tokens, tree.nodeData(value).node_and_node[0], summary_index),
        .@"orelse" => allocationFromValue(source, tree, tokens, tree.nodeData(value).node_and_node[0], summary_index) orelse
            allocationFromValue(source, tree, tokens, tree.nodeData(value).node_and_node[1], summary_index),
        .block_two, .block_two_semicolon, .block, .block_semicolon => allocationFromBlock(source, tree, tokens, value, summary_index),
        .call, .call_comma, .call_one, .call_one_comma => allocationFromCall(source, tree, tokens, value, summary_index),
        else => null,
    };
}

fn allocationFromBlock(
    source: []const u8,
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
    block: std.zig.Ast.Node.Index,
    summary_index: summaries.Index,
) ?Allocation {
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, block) orelse return null;
    for (statements) |statement| {
        if (tree.nodeTag(statement) != .@"break") continue;
        const break_value = tree.nodeData(statement).opt_token_and_opt_node[1].unwrap() orelse continue;
        if (allocationFromValue(source, tree, tokens, break_value, summary_index)) |allocation| return allocation;
    }
    return null;
}

fn allocationFromCall(
    source: []const u8,
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
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
            .receiver = if (allocator_argument) |argument|
                if (tree.nodeTag(argument) == .identifier) tree.tokenSlice(tree.nodeMainToken(argument)) else null
            else
                null,
            .allocator_source = if (allocator_argument) |argument| allocatorSourceName(source, tokens, tree, argument) else null,
        };
    }
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
    const receiver, const method_token = tree.nodeData(call.ast.fn_expr).node_and_token;
    const method = tree.tokenSlice(method_token);
    const receiver_name = if (tree.nodeTag(receiver) == .identifier) tree.tokenSlice(tree.nodeMainToken(receiver)) else null;
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
    if (allocationRelease(method)) |release| {
        if (std.mem.eql(u8, method, "create") and !expressionLooksLikeAllocationOwner(source, tokens, tree, receiver)) return null;
        if (std.mem.eql(u8, release, "free") and !expressionLooksLikeAllocator(source, tokens, tree, receiver)) return null;
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
    return .{
        .method = method,
        .release = owned.release,
        .receiver = if (allocator_argument) |argument|
            if (tree.nodeTag(argument) == .identifier) tree.tokenSlice(tree.nodeMainToken(argument)) else null
        else
            null,
        .allocator_source = if (allocator_argument) |argument| allocatorSourceName(source, tokens, tree, argument) else null,
    };
}

fn expressionLooksLikeAllocationOwner(
    source: []const u8,
    tokens: []const std.zig.Token,
    tree: *const std.zig.Ast,
    expression: std.zig.Ast.Node.Index,
) bool {
    if (expressionLooksLikeAllocator(source, tokens, tree, expression)) return true;
    return switch (tree.nodeTag(expression)) {
        .identifier => std.ascii.indexOfIgnoreCase(tree.tokenSlice(tree.nodeMainToken(expression)), "pool") != null,
        .field_access => std.ascii.indexOfIgnoreCase(tree.tokenSlice(tree.nodeData(expression).node_and_token[1]), "pool") != null,
        else => false,
    };
}

fn expressionLooksLikeAllocator(
    source: []const u8,
    tokens: []const std.zig.Token,
    tree: *const std.zig.Ast,
    expression: std.zig.Ast.Node.Index,
) bool {
    return switch (tree.nodeTag(expression)) {
        .identifier => identifier: {
            const name = tree.tokenSlice(tree.nodeMainToken(expression));
            break :identifier std.ascii.indexOfIgnoreCase(name, "alloc") != null or
                std.ascii.indexOfIgnoreCase(name, "arena") != null or
                std.mem.eql(u8, name, "gpa") or identifierHasAllocatorType(source, tokens, name);
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

fn identifierHasAllocatorType(source: []const u8, tokens: []const std.zig.Token, name: []const u8) bool {
    for (tokens, 0..) |token, identifier_index| {
        if (token.tag != .identifier or !tokenIsIdentifier(source, token, name) or
            identifier_index + 2 >= tokens.len or tokens[identifier_index + 1].tag != .colon) continue;
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

const arena_backed_types = [_][]const u8{ "ArenaAllocator", "FixedBufferAllocator" };

fn allocatorIsArenaBacked(source: []const u8, tokens: []const std.zig.Token, allocator_name: []const u8) bool {
    var name = allocator_name;
    for (0..4) |_| {
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

fn privateAllocatorParameterIsAlwaysArenaBacked(
    source: []const u8,
    tokens: []const std.zig.Token,
    declaration_index: usize,
    allocator_name: []const u8,
    summary_index: summaries.Index,
) bool {
    const function = summary_index.privateFunctionContaining(source, declaration_index) orelse return false;
    const parameter_index = for (function.parameter_names, 0..) |parameter, index| {
        if (std.mem.eql(u8, parameter, allocator_name)) break index;
    } else return false;

    var call_chain: [16]usize = undefined;
    return privateParameterIsAlwaysArenaBacked(
        source,
        tokens,
        function,
        parameter_index,
        summary_index,
        &call_chain,
        0,
    );
}

fn privateParameterIsAlwaysArenaBacked(
    source: []const u8,
    tokens: []const std.zig.Token,
    function: summaries.FunctionSummary,
    parameter_index: usize,
    summary_index: summaries.Index,
    call_chain: *[16]usize,
    call_depth: usize,
) bool {
    if (call_depth == call_chain.len) return false;
    for (call_chain[0..call_depth]) |body_start| if (body_start == function.body_start) return false;
    call_chain[call_depth] = function.body_start;
    var found_call = false;
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier or !tokenIsIdentifier(source, token, function.name)) continue;
        if (index > 0 and tokens[index - 1].tag == .keyword_fn) continue;
        if (index > 0 and tokens[index - 1].tag == .period) continue;
        if (index + 1 >= tokens.len or tokens[index + 1].tag != .l_paren) return false;
        const closing = matchingToken(tokens, index + 1, .l_paren, .r_paren) orelse return false;
        const argument = argument: {
            var argument_index: usize = 0;
            var argument_start = index + 2;
            var depth: usize = 0;
            for (tokens[index + 2 .. closing], index + 2..) |argument_token, argument_token_index| switch (argument_token.tag) {
                .l_paren, .l_bracket, .l_brace => depth += 1,
                .r_paren, .r_bracket, .r_brace => depth -|= 1,
                .comma => if (depth == 0) {
                    if (argument_index == parameter_index) break :argument TokenRange{
                        .start = argument_start,
                        .end = argument_token_index,
                    };
                    argument_index += 1;
                    argument_start = argument_token_index + 1;
                },
                else => {},
            };
            if (argument_index != parameter_index or argument_start >= closing) return false;
            break :argument TokenRange{ .start = argument_start, .end = closing };
        };
        const arena_backed = arena_backed: {
            if (argument.start + 2 < argument.end and tokens[argument.start].tag == .identifier and
                tokens[argument.start + 1].tag == .period and tokens[argument.start + 2].tag == .identifier and
                tokenIsIdentifier(source, tokens[argument.start + 2], "allocator"))
            {
                const receiver = source[tokens[argument.start].loc.start..tokens[argument.start].loc.end];
                break :arena_backed std.ascii.indexOfIgnoreCase(receiver, "arena") != null or
                    allocatorIsArenaBacked(source, tokens, receiver);
            }
            if (argument.start + 1 != argument.end or tokens[argument.start].tag != .identifier) {
                break :arena_backed false;
            }
            const argument_name = source[tokens[argument.start].loc.start..tokens[argument.start].loc.end];
            break :arena_backed std.ascii.indexOfIgnoreCase(argument_name, "arena") != null or
                allocatorIsArenaBacked(source, tokens, argument_name);
        };
        if (!arena_backed) {
            if (argument.start + 1 != argument.end or tokens[argument.start].tag != .identifier) return false;
            const caller = summary_index.privateFunctionContaining(source, index) orelse return false;
            const argument_name = source[tokens[argument.start].loc.start..tokens[argument.start].loc.end];
            const caller_parameter = for (caller.parameter_names, 0..) |parameter, caller_index| {
                if (std.mem.eql(u8, parameter, argument_name)) break caller_index;
            } else return false;
            if (!privateParameterIsAlwaysArenaBacked(
                source,
                tokens,
                caller,
                caller_parameter,
                summary_index,
                call_chain,
                call_depth + 1,
            )) return false;
        }
        found_call = true;
    }
    return found_call;
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
        {
            return source[tokens[index].loc.start..tokens[index].loc.end];
        }
    }
    return null;
}

fn allocationRelease(method: []const u8) ?[]const u8 {
    return owned_call.releaseForMethod(method);
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
        const receiver_name = releaseReceiverPath(source, tokens, method_index);
        const wrong_method = !std.mem.eql(u8, actual_release, allocation.release);
        const expected_allocator = allocation.receiver orelse allocation.allocator_source;
        const wrong_allocator = !receiver_is_binding and expected_allocator != null and receiver_name != null and
            !std.mem.eql(u8, expected_allocator.?, receiver_name.?);
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
                .{ binding_name, expected_allocator.?, receiver_name.? },
            );
        try found.append(allocator, .{
            .rule = .mismatched_allocation_release,
            .span = token.loc,
            .message = message,
        });
    }
    return mismatched;
}

fn releaseReceiverPath(source: []const u8, tokens: []const std.zig.Token, method_index: usize) ?[]const u8 {
    if (method_index < 2 or tokens[method_index - 1].tag != .period or
        tokens[method_index - 2].tag != .identifier) return null;
    var start = method_index - 2;
    while (start >= 2 and tokens[start - 1].tag == .period and tokens[start - 2].tag == .identifier) start -= 2;
    return source[tokens[start].loc.start..tokens[method_index - 2].loc.end];
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
    summary_index: summaries.Index,
    found: *std.ArrayList(Warning),
) !void {
    const declaration_scope = enclosingScope(tokens, declaration_index) orelse return;
    var releases: std.ArrayList(usize) = .empty;
    defer releases.deinit(allocator);
    for (tokens[declaration_end + 1 .. scope_end], declaration_end + 1..) |token, method_index| {
        if (token.tag != .identifier or method_index + 1 >= scope_end or tokens[method_index + 1].tag != .l_paren) continue;
        const release_scope = enclosingScope(tokens, method_index) orelse continue;
        if (release_scope.opening != declaration_scope.opening) continue;
        if (statementStartsWithErrdefer(tokens, method_index)) continue;
        const direct_release = tokenIsIdentifier(source, token, allocation.release) and
            releaseCallContainsBinding(source, tokens, scope_index, binding_name, binding_index, method_index, scope_end) and
            releaseUsesAllocationReceiver(source, tokens, scope_index, binding_name, binding_index, method_index, allocation.receiver);
        const summarized_release = localCallOwnership(
            source,
            tokens,
            scope_index,
            binding_name,
            binding_index,
            method_index + 1,
            summary_index,
        ) == .released;
        if (!direct_release and !summarized_release) continue;
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
                .fixes = try releaseDeletionFix(allocator, tokens, scope_index, release_index),
            });
        }
        if (!statementStartsWith(tokens, first_release, .keyword_defer) and
            !statementStartsWith(tokens, first_release, .keyword_errdefer))
        {
            const release_end = scope_index.statementEnd(first_release) orelse first_release;
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
    scope_index: *const syntax_scope.Index,
    release_index: usize,
) ![]const types.Fix {
    var statement_start = release_index;
    while (statement_start > 0) {
        switch (tokens[statement_start - 1].tag) {
            .semicolon, .l_brace, .r_brace => break,
            else => statement_start -= 1,
        }
    }
    const statement_end = scope_index.statementEnd(release_index) orelse release_index;
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
    const closing = scope_index.matchingToken(method_index + 1) orelse return false;
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
        lastCallArgumentStart(tokens, method_index + 1, closing),
        closing,
    );
}

fn lastCallArgumentStart(tokens: []const std.zig.Token, opening: usize, closing: usize) usize {
    var parentheses: usize = 0;
    var brackets: usize = 0;
    var braces: usize = 0;
    var start = opening + 1;
    for (tokens[opening + 1 .. closing], opening + 1..) |token, index| switch (token.tag) {
        .l_paren => parentheses += 1,
        .r_paren => parentheses -|= 1,
        .l_bracket => brackets += 1,
        .r_bracket => brackets -|= 1,
        .l_brace => braces += 1,
        .r_brace => braces -|= 1,
        .comma => if (parentheses == 0 and brackets == 0 and braces == 0) {
            start = index + 1;
        },
        else => {},
    };
    return start;
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
        if (index > start and tokens[index - 1].tag == .period) continue;
        if (index + 1 < end and tokens[index + 1].tag == .period) continue;
        if (index + 1 < end and tokens[index + 1].tag == .l_bracket) continue;
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
                scope_index.matchingToken(release_index + 1)
            else
                null;
            if (closing) |closing_index| if (index >= release_index -| 2 and index <= closing_index) {
                belongs_to_release = true;
                break;
            };
        }
        if (belongs_to_release) continue;
        if (index + 1 < tokens.len and tokens[index + 1].tag == .equal) return null;
        if (!useDefinitelyReadsReleasedAllocation(source, tokens, index, end)) continue;
        return index;
    }
    return null;
}

fn useDefinitelyReadsReleasedAllocation(source: []const u8, tokens: []const std.zig.Token, use_index: usize, end: usize) bool {
    if (use_index + 1 >= end) return false;
    if (tokens[use_index + 1].tag == .l_bracket or tokens[use_index + 1].tag == .period_asterisk) return true;
    if (use_index + 2 >= end or tokens[use_index + 1].tag != .period or tokens[use_index + 2].tag != .identifier) return false;
    const member = source[tokens[use_index + 2].loc.start..tokens[use_index + 2].loc.end];
    if (std.mem.eql(u8, member, "len")) return false;
    if (!std.mem.eql(u8, member, "ptr")) return true;
    return use_index + 3 < end and
        (tokens[use_index + 3].tag == .period_asterisk or tokens[use_index + 3].tag == .l_bracket);
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
        const statement_end = scope_index.statementEnd(index) orelse continue;
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
            const closing = scope_index.matchingToken(rhs_index + 1) orelse continue;
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
    summary_index: summaries.Index,
) Cleanup {
    var found_errdefer = false;
    for (tokens[start..end], start..) |token, index| {
        if ((token.tag == .keyword_return or token.tag == .keyword_break) and
            controlFlowValueContainsBinding(source, tokens, scope_index, binding_name, binding_index, index + 1, end)) return .released;
        if (token.tag != .identifier) continue;
        const method = source[token.loc.start..token.loc.end];
        const expected_cleanup = std.mem.eql(u8, method, release_method);
        if (!expected_cleanup and !conventionalCleanupMethod(method)) continue;
        if (index == 0 or index + 2 >= end or tokens[index - 1].tag != .period or tokens[index + 1].tag != .l_paren) {
            continue;
        }
        const closing_parenthesis = scope_index.matchingToken(index + 1) orelse continue;
        if (closing_parenthesis >= end) continue;
        const receiver_is_binding = index >= 2 and tokenIsIdentifier(source, tokens[index - 2], binding_name) and
            identifierRefersToBinding(scope_index, binding_index, index - 2);
        const argument_start = lastCallArgumentStart(tokens, index + 1, closing_parenthesis);
        const argument_contains_binding = releaseArgumentContainsBinding(
            source,
            tokens,
            scope_index,
            binding_name,
            binding_index,
            argument_start,
            closing_parenthesis,
        ) or releaseArgumentContainsOptionalCapture(
            source,
            tokens,
            scope_index,
            binding_name,
            binding_index,
            start,
            argument_start,
            closing_parenthesis,
            index,
        );
        const receiver_cleanup = receiver_is_binding and conventionalCleanupMethod(method);
        if (!receiver_cleanup and (!expected_cleanup or !argument_contains_binding)) continue;
        if (!statementStartsWithErrdefer(tokens, index)) return .released;
        found_errdefer = true;
    }
    if (localHelperReleasesBinding(
        source,
        tokens,
        scope_index,
        binding_name,
        binding_index,
        start,
        end,
        summary_index,
    )) return .released;
    if (bindingEscapes(source, tokens, scope_index, binding_name, binding_index, start, end, release_method, summary_index)) return .released;
    return if (found_errdefer) .errdefer_only else .missing;
}

fn releaseArgumentContainsOptionalCapture(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    search_start: usize,
    argument_start: usize,
    argument_end: usize,
    release_index: usize,
) bool {
    for (tokens[argument_start..argument_end], argument_start..) |argument, argument_index| {
        if (argument.tag != .identifier) continue;
        const capture_name = source[argument.loc.start..argument.loc.end];
        var capture_index = search_start;
        while (capture_index + 3 < release_index) : (capture_index += 1) {
            if (tokens[capture_index].tag != .pipe or tokens[capture_index + 1].tag != .identifier or
                !tokenIsIdentifier(source, tokens[capture_index + 1], capture_name) or
                tokens[capture_index + 2].tag != .pipe) continue;
            const body_end = if (tokens[capture_index + 3].tag == .l_brace)
                scope_index.matchingToken(capture_index + 3) orelse continue
            else
                scope_index.statementEnd(capture_index + 3) orelse continue;
            if (body_end < release_index) continue;
            var if_index = search_start;
            while (if_index + 1 < capture_index) : (if_index += 1) {
                if (tokens[if_index].tag != .keyword_if or tokens[if_index + 1].tag != .l_paren) continue;
                const condition_end = scope_index.matchingToken(if_index + 1) orelse continue;
                if (condition_end + 1 != capture_index or
                    !identifierRefersToBinding(scope_index, capture_index + 1, argument_index) or !containsBinding(
                    source,
                    tokens,
                    scope_index,
                    binding_name,
                    binding_index,
                    if_index + 2,
                    condition_end,
                )) continue;
                return true;
            }
        }
    }
    return false;
}

fn conventionalCleanupMethod(method: []const u8) bool {
    const methods = [_][]const u8{ "close", "deinit", "delete", "destroy", "free", "release", "shutdown" };
    for (methods) |candidate| if (std.mem.eql(u8, method, candidate)) return true;
    return false;
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
    const end = @min(scope_index.statementEnd(start) orelse scope_end, scope_end);
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
    summary_index: summaries.Index,
) bool {
    for (tokens[start..end], start..) |token, index| {
        if (tokenIsIdentifier(source, token, binding_name) and
            identifierRefersToBinding(scope_index, binding_index, index) and
            index + 3 < end and tokens[index + 1].tag == .period and
            tokens[index + 2].tag == .identifier and tokens[index + 3].tag == .l_paren)
        {
            return true;
        }
        if (token.tag == .l_paren and index > 0 and
            (tokens[index - 1].tag == .identifier or tokens[index - 1].tag == .builtin))
        {
            const closing = scope_index.matchingToken(index) orelse continue;
            if (closing >= end or !containsBinding(source, tokens, scope_index, binding_name, binding_index, index + 1, closing)) continue;
            if (callOnlyUsesScalarProjections(
                source,
                tokens,
                scope_index,
                binding_name,
                binding_index,
                index + 1,
                closing,
            )) continue;
            const method = source[tokens[index - 1].loc.start..tokens[index - 1].loc.end];
            if (std.mem.eql(u8, method, release_method)) {
                const method_call = index >= 2 and tokens[index - 2].tag == .period;
                if (method_call) continue;
                return true;
            }
            if (tokens[index - 1].tag == .identifier) {
                switch (localCallOwnership(
                    source,
                    tokens,
                    scope_index,
                    binding_name,
                    binding_index,
                    index,
                    summary_index,
                )) {
                    .borrowed, .released => continue,
                    .unknown => {},
                }
            }
            if (tokens[index - 1].tag == .builtin and builtinBorrowsMemory(method)) continue;
            return true;
        }
        if (token.tag != .equal) continue;
        const statement_end = scope_index.statementEnd(index) orelse continue;
        if (statement_end >= end or
            !containsBinding(source, tokens, scope_index, binding_name, binding_index, index + 1, statement_end) or
            assignmentDiscards(source, tokens, start, index)) continue;
        if (index >= 2 and (tokens[index - 2].tag == .keyword_const or tokens[index - 2].tag == .keyword_var) and
            localDeclarationCreatesBorrowingView(
                source,
                tokens,
                scope_index,
                binding_name,
                binding_index,
                index + 1,
                statement_end,
            )) continue;
        return true;
    }
    return false;
}

fn callOnlyUsesScalarProjections(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    start: usize,
    end: usize,
) bool {
    var found = false;
    for (tokens[start..end], start..) |token, index| {
        if (!tokenIsIdentifier(source, token, binding_name) or
            !identifierRefersToBinding(scope_index, binding_index, index)) continue;
        found = true;
        if (index + 2 < end and tokens[index + 1].tag == .period and
            tokenIsIdentifier(source, tokens[index + 2], "len")) continue;
        if (index + 1 < end and tokens[index + 1].tag == .l_bracket) {
            const bracket_end = scope_index.matchingToken(index + 1) orelse return false;
            if (bracket_end >= end) return false;
            var is_slice = false;
            for (tokens[index + 2 .. bracket_end]) |part| {
                if (part.tag == .ellipsis2 or part.tag == .ellipsis3) {
                    is_slice = true;
                    break;
                }
            }
            if (!is_slice) continue;
        }
        return false;
    }
    return found;
}

fn localDeclarationCreatesBorrowingView(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    start: usize,
    end: usize,
) bool {
    for (tokens[start..end], start..) |token, call_open| {
        if (token.tag != .l_paren or call_open == 0 or tokens[call_open - 1].tag != .identifier) continue;
        const call_close = scope_index.matchingToken(call_open) orelse continue;
        if (call_close >= end) continue;
        const argument_index = bareBindingArgumentIndex(
            source,
            tokens,
            scope_index,
            binding_name,
            binding_index,
            call_open + 1,
            call_close,
        ) orelse continue;
        var callable_start = call_open - 1;
        while (callable_start >= 2 and tokens[callable_start - 1].tag == .period and
            tokens[callable_start - 2].tag == .identifier) callable_start -= 2;
        const callable = source[tokens[callable_start].loc.start..tokens[call_open - 1].loc.end];
        if (conventionalBorrowingCall(callable, argument_index, callArgumentCount(tokens, call_open + 1, call_close))) return true;
    }
    return false;
}

fn builtinBorrowsMemory(name: []const u8) bool {
    return std.mem.eql(u8, name, "@memcpy") or std.mem.eql(u8, name, "@memset");
}

const CallOwnership = enum { borrowed, released, unknown };

fn localHelperReleasesBinding(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    start: usize,
    end: usize,
    summary_index: summaries.Index,
) bool {
    for (tokens[start..end], start..) |token, call_open| {
        if (token.tag != .l_paren or call_open == 0 or tokens[call_open - 1].tag != .identifier) continue;
        const closing = scope_index.matchingToken(call_open) orelse continue;
        if (closing >= end or !containsBinding(
            source,
            tokens,
            scope_index,
            binding_name,
            binding_index,
            call_open + 1,
            closing,
        )) continue;
        if (localCallOwnership(
            source,
            tokens,
            scope_index,
            binding_name,
            binding_index,
            call_open,
            summary_index,
        ) == .released) return true;
    }
    return false;
}

fn localCallOwnership(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    call_open: usize,
    summary_index: summaries.Index,
) CallOwnership {
    if (call_open == 0 or tokens[call_open - 1].tag != .identifier) return .unknown;
    const call_close = scope_index.matchingToken(call_open) orelse return .unknown;
    const containing_argument = bindingArgumentIndex(
        source,
        tokens,
        scope_index,
        binding_name,
        binding_index,
        call_open + 1,
        call_close,
    ) orelse return .unknown;
    var callable_start = call_open - 1;
    while (callable_start >= 2 and tokens[callable_start - 1].tag == .period and
        tokens[callable_start - 2].tag == .identifier) callable_start -= 2;
    const callable = source[tokens[callable_start].loc.start..tokens[call_open - 1].loc.end];
    const argument_count = callArgumentCount(tokens, call_open + 1, call_close);
    const method = if (std.mem.lastIndexOfScalar(u8, callable, '.')) |separator| callable[separator + 1 ..] else callable;
    if (containing_argument == 2 and argument_count >= 6 and
        std.mem.eql(u8, method, "write") and
        asyncWriteCallbackReleasesBuffer(source, tokens, scope_index, call_open, call_close)) return .released;
    if (conventionalBorrowingCall(callable, containing_argument, argument_count)) return .borrowed;
    const argument_index = bareBindingArgumentIndex(
        source,
        tokens,
        scope_index,
        binding_name,
        binding_index,
        call_open + 1,
        call_close,
    ) orelse return .unknown;
    return switch (summary_index.parameterEffectForCall(source, callable, argument_index)) {
        .borrowed => .borrowed,
        .released => .released,
        .escaped, .unknown => .unknown,
    };
}

fn asyncWriteCallbackReleasesBuffer(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    call_open: usize,
    call_close: usize,
) bool {
    const callback_start = lastCallArgumentStart(tokens, call_open, call_close);
    if (callback_start + 1 != call_close or tokens[callback_start].tag != .identifier) return false;
    const callback_binding = scope_index.findBinding(callback_start) orelse return false;
    if (callback_binding.token_index == 0 or tokens[callback_binding.token_index - 1].tag != .keyword_fn) return false;
    const function_index = callback_binding.token_index - 1;
    if (function_index + 2 >= tokens.len or tokens[function_index + 2].tag != .l_paren) return false;
    const parameters_end = scope_index.matchingToken(function_index + 2) orelse return false;
    var parameter_index: usize = 0;
    var segment_start = function_index + 3;
    var depth: usize = 0;
    var buffer_parameter: ?[]const u8 = null;
    var index = segment_start;
    while (index <= parameters_end) : (index += 1) {
        const at_end = index == parameters_end;
        if (!at_end) switch (tokens[index].tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            else => {},
        };
        if (!at_end and (tokens[index].tag != .comma or depth != 0)) continue;
        if (parameter_index == 4) {
            for (tokens[segment_start..index], segment_start..) |parameter, name_index| {
                if (parameter.tag == .identifier and name_index + 1 < index and tokens[name_index + 1].tag == .colon) {
                    buffer_parameter = source[parameter.loc.start..parameter.loc.end];
                    break;
                }
            }
            break;
        }
        parameter_index += 1;
        segment_start = index + 1;
    }
    const buffer_name = buffer_parameter orelse return false;
    const body_start = syntax_scope.functionBodyAfterParameters(tokens, parameters_end) orelse return false;
    const body_end = scope_index.matchingToken(body_start) orelse return false;
    for (tokens[body_start + 1 .. body_end], body_start + 1..) |token, method_index| {
        if (token.tag != .identifier or method_index + 1 >= body_end or tokens[method_index + 1].tag != .l_paren) continue;
        const method = source[token.loc.start..token.loc.end];
        if (!std.mem.eql(u8, method, "destroy") and !std.mem.eql(u8, method, "free") and
            !std.mem.eql(u8, method, "deinit") and !std.mem.eql(u8, method, "release")) continue;
        const cleanup_end = scope_index.matchingToken(method_index + 1) orelse continue;
        for (tokens[method_index + 2 .. @min(cleanup_end, body_end)]) |argument| {
            if (tokenIsIdentifier(source, argument, buffer_name)) return true;
        }
    }
    return false;
}

fn bindingArgumentIndex(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    start: usize,
    end: usize,
) ?usize {
    var argument_index: usize = 0;
    var segment_start = start;
    var depth: usize = 0;
    var index = start;
    while (index <= end) : (index += 1) {
        const at_end = index == end;
        if (!at_end) switch (tokens[index].tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            else => {},
        };
        if (!at_end and (tokens[index].tag != .comma or depth != 0)) continue;
        if (containsBinding(source, tokens, scope_index, binding_name, binding_index, segment_start, index)) return argument_index;
        argument_index += 1;
        segment_start = index + 1;
    }
    return null;
}

fn conventionalBorrowingCall(callable: []const u8, argument_index: usize, argument_count: usize) bool {
    const separator = std.mem.lastIndexOfScalar(u8, callable, '.');
    const method = if (separator) |index| callable[index + 1 ..] else callable;
    const methods = [_][]const u8{ "appendSlice", "writeAll", "writeStreamingAll", "print" };
    for (methods) |candidate| if (std.mem.eql(u8, method, candidate)) return argument_index + 1 == argument_count;
    if (std.mem.eql(u8, method, "write")) {
        if (argument_count >= 6) return argument_index == 2;
        return argument_index + 1 == argument_count;
    }
    const slice_iterators = [_][]const u8{
        "splitAny",
        "splitBackwardsAny",
        "splitBackwardsScalar",
        "splitBackwardsSequence",
        "splitScalar",
        "splitSequence",
        "tokenizeAny",
        "tokenizeScalar",
        "tokenizeSequence",
        "window",
    };
    for (slice_iterators) |candidate| {
        if (std.mem.eql(u8, method, candidate)) return argument_index == 1;
    }
    return false;
}

fn callArgumentCount(tokens: []const std.zig.Token, start: usize, end: usize) usize {
    if (start >= end) return 0;
    var count: usize = 1;
    var depth: usize = 0;
    for (tokens[start..end]) |token| switch (token.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .comma => if (depth == 0) {
            count += 1;
        },
        else => {},
    };
    return count;
}

fn bareBindingArgumentIndex(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    start: usize,
    end: usize,
) ?usize {
    var argument_index: usize = 0;
    var segment_start = start;
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    for (tokens[start..end], start..) |token, index| {
        const segment_end = token.tag == .comma and parenthesis_depth == 0 and
            bracket_depth == 0 and brace_depth == 0;
        if (segment_end) {
            if (index == segment_start + 1 and tokenRefersToBinding(source, tokens, segment_start, binding_name) and
                identifierRefersToBinding(scope_index, binding_index, segment_start)) return argument_index;
            argument_index += 1;
            segment_start = index + 1;
            continue;
        }
        switch (token.tag) {
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .l_bracket => bracket_depth += 1,
            .r_bracket => bracket_depth -|= 1,
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            else => {},
        }
    }
    if (end == segment_start + 1 and tokenRefersToBinding(source, tokens, segment_start, binding_name) and
        identifierRefersToBinding(scope_index, binding_index, segment_start)) return argument_index;
    return null;
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
    scope_index: *const syntax_scope.Index,
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
            scope_index.matchingToken(index + 1) orelse scope_end
        else
            scope_index.statementEnd(index + 1) orelse scope_end;
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

test "field insertion is not confused with a same named owner method" {
    const source =
        "const Table = struct { names: List, allocator: std.mem.Allocator," ++
        "fn append(self: *Table, name: []const u8) !void {" ++
        "const owned_name = try self.allocator.dupe(u8, name);" ++
        "errdefer self.allocator.free(owned_name);" ++
        "try self.names.append(self.allocator, owned_name); } };";
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

test "passing an allocation to a proven borrowing helper does not transfer ownership" {
    const source =
        "fn inspect(bytes: []u8) void { _ = bytes.len; }" ++
        "fn leak(allocator: std.mem.Allocator) !void {" ++
        "const bytes = try allocator.alloc(u8, 16);" ++
        "inspect(bytes);" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "copying allocation bytes into a container does not transfer ownership" {
    const source =
        "fn append(allocator: std.mem.Allocator, output: *List) !void {" ++
        "const line = try std.fmt.allocPrint(allocator, \"value\", .{});" ++
        "try output.appendSlice(allocator, line);" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "a proven releasing helper discharges caller ownership" {
    const source =
        "fn release(allocator: std.mem.Allocator, bytes: []u8) void { allocator.free(bytes); }" ++
        "fn clean(allocator: std.mem.Allocator) !void {" ++
        "const bytes = try allocator.alloc(u8, 16);" ++
        "release(allocator, bytes);" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "summary-backed releases participate in double release and use-after proof" {
    const source =
        "fn release(allocator: std.mem.Allocator, bytes: []u8) void { allocator.free(bytes); }" ++
        "fn misuse(allocator: std.mem.Allocator) !void {" ++
        "const bytes = try allocator.alloc(u8, 16);" ++
        "release(allocator, bytes);" ++
        "release(allocator, bytes);" ++
        "_ = bytes[0];" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    var saw_double_release = false;
    var saw_use_after_release = false;
    for (found) |warning| switch (warning.rule) {
        .double_release => saw_double_release = true,
        .use_after_release => saw_use_after_release = true,
        else => {},
    };
    try std.testing.expect(saw_double_release);
    try std.testing.expect(saw_use_after_release);
}

test "errdefer and success cleanup are not a double release" {
    const source =
        "fn run(allocator: std.mem.Allocator) !void {" ++
        "const bytes = try allocator.alloc(u8, 16);" ++
        "errdefer allocator.free(bytes);" ++
        "allocator.free(bytes);" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "optional capture cleanup releases an optional owned return" {
    const source =
        "fn make(allocator: std.mem.Allocator) ![]u8 { return allocator.alloc(u8, 16); }" ++
        "fn run(allocator: std.mem.Allocator) void {" ++
        "const maybe_bytes = make(allocator) catch null;" ++
        "if (maybe_bytes) |bytes| { defer allocator.free(bytes); inspect(bytes); }" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "an indirect helper transfer remains conservative" {
    const source =
        "fn register(bytes: []u8) void { store(bytes); }" ++
        "fn attach(allocator: std.mem.Allocator) !void {" ++
        "const bytes = try allocator.alloc(u8, 16);" ++
        "register(bytes);" ++
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

test "arena allocations cannot be released through an unrelated allocator" {
    const source =
        "fn bad(other: std.mem.Allocator, arena: *std.heap.ArenaAllocator) !void {" ++
        "const bytes = try arena.allocator().dupe(u8, \"x\"); other.free(bytes); }";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.mismatched_allocation_release, found[0].rule);
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
        "fn resolve(b: std.mem.Allocator, existing: ?[]u8) void {" ++
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

test "releasing an owned field does not release its parent allocation" {
    const source =
        "fn createButton(allocator: std.mem.Allocator, label: []const u8) !*Button {" ++
        "const self = try allocator.create(Button);" ++
        "errdefer allocator.destroy(self);" ++
        "self.label = try allocator.dupe(u8, label);" ++
        "errdefer allocator.free(self.label);" ++
        "return self;" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "arbitrary create methods are not assumed to allocate" {
    const source =
        "fn run(protocol: *Protocol) !void {" ++
        "const result = try protocol.create();" ++
        "result.send();" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "opaque methods may take ownership of pool allocations" {
    const source =
        "fn run(self: *Server, allocator: std.mem.Allocator) !void {" ++
        "const socket = try self.socket_pool.create(allocator);" ++
        "socket.read();" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "async operations take ownership of non-buffer pool arguments" {
    const source =
        "fn run(self: *Client, allocator: std.mem.Allocator, socket: anytype, loop: anytype) void {" ++
        "const completion = self.completion_pool.create(allocator) catch unreachable;" ++
        "socket.write(loop, completion, .{ .slice = \"ping\" }, Client, self, callback);" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "async writes continue borrowing their buffer argument" {
    const source =
        "fn run(self: *Client, allocator: std.mem.Allocator, socket: anytype, loop: anytype) void {" ++
        "const bytes = allocator.alloc(u8, 4) catch unreachable;" ++
        "socket.write(loop, completion, bytes, Client, self, callback);" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
}

test "async write callbacks can release the submitted buffer" {
    const source =
        "const Client = struct { fn writeCallback(self: *Client, loop: anytype, completion: anytype, socket: anytype, buffer: anytype, result: anytype) void {" ++
        "_ = self; _ = loop; _ = completion; _ = socket; _ = buffer; _ = result; } };" ++
        "const Server = struct { buffer_pool: Pool, fn send(self: *Server, allocator: std.mem.Allocator, socket: anytype, loop: anytype) void {" ++
        "_ = allocator; const bytes = self.buffer_pool.create(allocator) catch unreachable; socket.write(loop, completion, .{ .slice = bytes[0..4] }, Server, self, writeCallback); }" ++
        "fn writeCallback(self: *Server, loop: anytype, completion: anytype, socket: anytype, buffer: anytype, result: anytype) void {" ++
        "_ = loop; _ = completion; _ = socket; _ = result; self.buffer_pool.destroy(@alignCast(@as(*[4096]u8, @ptrFromInt(@intFromPtr(buffer.slice.ptr))))); } };";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "inline optional defer releases an optional allocation" {
    const source =
        "fn run(allocator: std.mem.Allocator) !void {" ++
        "const maybe_bytes: ?[]u8 = try allocator.alloc(u8, 4);" ++
        "defer if (maybe_bytes) |bytes| allocator.free(bytes);" ++
        "try consume(maybe_bytes);" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
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

test "dupe methods use a proven allocator receiver" {
    const wrapper_source =
        "fn run(index_slice: anytype, gpa: std.mem.Allocator, ip: anytype) !void {" ++
        "const indices = try index_slice.dupe(gpa, ip);" ++
        "defer gpa.free(indices);" ++
        "}";
    const wrapper_findings = try warnings(std.testing.allocator, wrapper_source);
    defer freeWarnings(std.testing.allocator, wrapper_findings);
    try std.testing.expectEqual(@as(usize, 0), wrapper_findings.len);

    const allocator_source =
        "fn run(a: std.mem.Allocator, other: std.mem.Allocator, bytes: []const u8) !void {" ++
        "const copy = try a.dupe(u8, bytes);" ++
        "defer other.free(copy);" ++
        "}";
    const allocator_findings = try warnings(std.testing.allocator, allocator_source);
    defer freeWarnings(std.testing.allocator, allocator_findings);
    try std.testing.expectEqual(@as(usize, 1), allocator_findings.len);
    try std.testing.expectEqual(types.Rule.mismatched_allocation_release, allocator_findings[0].rule);
}

test "standard allocation helpers use their allocator argument" {
    const source =
        "fn run(allocator: std.mem.Allocator, parts: []const []const u8) !void {" ++
        "const joined = try std.mem.concat(allocator, u8, parts);" ++
        "_ = joined.len;" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "allocator fields preserve provenance through standard helpers" {
    const source =
        "fn run(self: *State) !void {" ++
        "const path = try std.fs.path.resolve(self.alloc, &.{\"a\", \"b\"});" ++
        "defer self.alloc.free(path);" ++
        "const text = try std.fmt.allocPrint(self.alloc, \"{s}\", .{path});" ++
        "defer self.alloc.free(text);" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "different allocator fields remain distinct provenance" {
    const source =
        "fn run(self: *State, other: *State) !void {" ++
        "const text = try std.fmt.allocPrint(self.alloc, \"value\", .{});" ++
        "defer other.alloc.free(text);" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.mismatched_allocation_release, found[0].rule);
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
        "_ = buffer[0];" ++
        "}";
    const use_findings = try warnings(std.testing.allocator, use_source);
    defer freeWarnings(std.testing.allocator, use_findings);
    var saw_use = false;
    for (use_findings) |finding| {
        if (finding.rule == .use_after_release) saw_use = true;
    }
    try std.testing.expect(saw_use);
}

test "released slice metadata remains usable without reading freed memory" {
    const source =
        "fn run(a: std.mem.Allocator) !void {" ++
        "const buffer = try a.alloc(u8, 16);" ++
        "a.free(buffer);" ++
        "_ = @intFromPtr(buffer.ptr);" ++
        "_ = buffer.len;" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    for (found) |warning| try std.testing.expect(warning.rule != .use_after_release);
}

test "passing a released value is not by itself proof of a memory read" {
    const source =
        "fn run(a: std.mem.Allocator, owner: anytype) !void {" ++
        "const buffer = try a.alloc(u8, 16);" ++
        "a.free(buffer);" ++
        "_ = owner.isAllocated(buffer);" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    for (found) |warning| try std.testing.expect(warning.rule != .use_after_release);
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

test "private allocation functions called only with an arena allocator are exempt" {
    const source =
        "fn normalize(alloc: std.mem.Allocator, input: []const u8) !void {" ++
        "var lowered = try alloc.dupe(u8, input);" ++
        "lowered = try alloc.dupe(u8, lowered);" ++
        "}" ++
        "fn run(gpa: std.mem.Allocator, input: []const u8) !void {" ++
        "var arena = std.heap.ArenaAllocator.init(gpa);" ++
        "defer arena.deinit();" ++
        "const a = arena.allocator();" ++
        "try normalize(a, input);" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "private allocation functions remain checked when any caller uses a general allocator" {
    const source =
        "fn normalize(alloc: std.mem.Allocator, input: []const u8) !void {" ++
        "var lowered = try alloc.dupe(u8, input);" ++
        "lowered = try alloc.dupe(u8, lowered);" ++
        "defer alloc.free(lowered);" ++
        "}" ++
        "fn run(gpa: std.mem.Allocator, input: []const u8) !void {" ++
        "try normalize(gpa, input);" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    var saw_overwrite = false;
    for (found) |finding| if (finding.rule == .overwritten_owning_value) {
        saw_overwrite = true;
    };
    try std.testing.expect(saw_overwrite);
}

test "public allocation functions remain checked despite local arena callers" {
    const source =
        "pub inline fn normalize(alloc: std.mem.Allocator, input: []const u8) !void {" ++
        "var lowered = try alloc.dupe(u8, input);" ++
        "lowered = try alloc.dupe(u8, lowered);" ++
        "defer alloc.free(lowered);" ++
        "}" ++
        "fn run(gpa: std.mem.Allocator, input: []const u8) !void {" ++
        "var arena = std.heap.ArenaAllocator.init(gpa);" ++
        "defer arena.deinit();" ++
        "try normalize(arena.allocator(), input);" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    var saw_overwrite = false;
    for (found) |finding| if (finding.rule == .overwritten_owning_value) {
        saw_overwrite = true;
    };
    try std.testing.expect(saw_overwrite);
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

test "custom allocator free does not release its backing buffer argument" {
    const source =
        "fn run(a: std.mem.Allocator, bitmap: anytype, ptr: [*]u8) !void {" ++
        "const backing = try a.alloc(u8, 16);" ++
        "defer a.free(backing);" ++
        "bitmap.free(backing, ptr);" ++
        "_ = backing.ptr;" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "custom allocator free releases its final allocation argument" {
    const source =
        "fn run(a: std.mem.Allocator, bitmap: anytype, backing: []u8) !void {" ++
        "const ptr = try bitmap.alloc(u8, backing, 16);" ++
        "bitmap.free(backing, ptr);" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "owned wrapper values may use conventional cleanup methods" {
    const source =
        "fn rasterize(a: std.mem.Allocator) !Bitmap { return .{ .data = try a.alloc(u8, 16) }; }" ++
        "fn createThing(a: std.mem.Allocator) !*Thing { const thing = try a.create(Thing); return thing; }" ++
        "fn run(a: std.mem.Allocator) !void {" ++
        "var bitmap = try rasterize(a);" ++
        "defer bitmap.deinit(a);" ++
        "const thing = try createThing(a);" ++
        "defer thing.shutdown();" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "owned returns allocated by an arena parameter need no individual cleanup" {
    const source =
        "fn nodesAtLoc(arena: std.mem.Allocator) ![]Node { return arena.alloc(Node, 4); }" ++
        "fn run(arena: std.mem.Allocator) !void {" ++
        "const nodes = try nodesAtLoc(arena);" ++
        "_ = nodes;" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "owned returns allocated through an arena field need no individual cleanup" {
    const source =
        "fn nodesAtLoc(allocator: std.mem.Allocator) ![]Node { return allocator.alloc(Node, 4); }" ++
        "fn run(context: anytype) !void {" ++
        "const nodes = try nodesAtLoc(context.state.arena);" ++
        "_ = nodes;" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "qualified constructors passed an arena inherit its lifetime" {
    const source =
        "const ZigTag = struct { const node = struct { fn create(allocator: std.mem.Allocator) !*Node { return allocator.create(Node); } }; };" ++
        "fn run(context: anytype) !void {" ++
        "const node = try ZigTag.node.create(context.state.arena);" ++
        "_ = node;" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "qualified init calls do not inherit unrelated local summaries" {
    const source =
        "fn init(a: std.mem.Allocator) !Owner { return .{ .bytes = try a.alloc(u8, 4) }; }" ++
        "fn run() void { var random = std.Random.DefaultPrng.init(1); _ = random.random(); }";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "derived allocation passed to an unqualified free wrapper transfers ownership" {
    const source =
        "fn run(a: std.mem.Allocator) !void {" ++
        "const memory = try a.alloc(u8, 8);" ++
        "free(null, memory.ptr, memory.len);" ++
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

test "memory builtins borrow allocations" {
    const source =
        "fn zero(a: std.mem.Allocator) !void {" ++
        "const counts = try a.alloc(u8, 4);" ++
        "@memset(counts, 0);" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "formatting allocation metadata does not transfer ownership" {
    const source =
        "fn run(allocator: std.mem.Allocator) !void {" ++
        "const bytes = try allocator.alloc(u8, 4); std.debug.print(\"{d}\", .{bytes.len}); }";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "formatting an allocation does not transfer ownership" {
    const source =
        "fn run(allocator: std.mem.Allocator) !void {" ++
        "const bytes = try allocator.alloc(u8, 4); std.debug.print(\"{s}\", .{bytes}); }";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "reader allocRemaining returns memory owned by its allocator argument" {
    const source =
        "fn readAll(reader: *Reader, allocator: std.mem.Allocator) !void {" ++
        "const bytes = try reader.interface.allocRemaining(allocator, .unlimited);" ++
        "var tokens = std.mem.tokenizeAny(u8, bytes, \" \");" ++
        "_ = tokens.next();" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
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

test "aggregate errdefer cannot overlap direct field cleanup" {
    const source =
        "const Frame = struct { payload: []u8, fn deinit(self: *Frame, allocator: std.mem.Allocator) void {" ++
        "allocator.free(self.payload); allocator.destroy(self); } };" ++
        "fn decode(allocator: std.mem.Allocator) !*Frame {" ++
        "const payload = try allocator.dupe(u8, \"frame\");" ++
        "const frame = try allocator.create(Frame);" ++
        "errdefer allocator.free(payload); errdefer allocator.destroy(frame);" ++
        "frame.* = .{ .payload = payload }; errdefer frame.deinit(allocator);" ++
        "try decodeChildren(); return frame; }";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    var double_release_count: usize = 0;
    for (found) |warning| if (warning.rule == .double_release) {
        double_release_count += 1;
        try std.testing.expect(std.mem.indexOf(u8, warning.message, "owned field 'payload'") != null);
    };
    try std.testing.expectEqual(@as(usize, 1), double_release_count);
}

test "aggregate errdefer without earlier field cleanup stays clean" {
    const source =
        "const Frame = struct { payload: []u8, fn deinit(self: *Frame, allocator: std.mem.Allocator) void {" ++
        "allocator.free(self.payload); allocator.destroy(self); } };" ++
        "fn decode(allocator: std.mem.Allocator) !*Frame {" ++
        "const payload = try allocator.dupe(u8, \"frame\");" ++
        "const frame = try allocator.create(Frame); errdefer allocator.destroy(frame);" ++
        "frame.* = .{ .payload = payload }; errdefer frame.deinit(allocator);" ++
        "try decodeChildren(); return frame; }";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    for (found) |warning| try std.testing.expect(warning.rule != .double_release);
}

test "aggregate errdefer ignores field cleanup from a closed sibling scope" {
    const source =
        "const Frame = struct { payload: []u8, fn deinit(self: *Frame, allocator: std.mem.Allocator) void {" ++
        "allocator.free(self.payload); allocator.destroy(self); } };" ++
        "fn decode(allocator: std.mem.Allocator, alternate: bool) !*Frame {" ++
        "if (alternate) { const payload = try allocator.dupe(u8, \"old\"); errdefer allocator.free(payload); allocator.free(payload); }" ++
        "const payload = try allocator.dupe(u8, \"frame\"); const frame = try allocator.create(Frame);" ++
        "errdefer allocator.destroy(frame); frame.* = .{ .payload = payload }; errdefer frame.deinit(allocator); return frame; }";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    for (found) |warning| try std.testing.expect(warning.rule != .double_release);
}

test "aggregate cleanup only overlaps fields released from its receiver" {
    const source =
        "const Frame = struct { payload: []u8, other: *Frame, fn deinit(self: *Frame, allocator: std.mem.Allocator) void {" ++
        "allocator.free(self.other.payload); allocator.destroy(self); } };" ++
        "fn decode(allocator: std.mem.Allocator) !*Frame { const payload = try allocator.dupe(u8, \"frame\");" ++
        "errdefer allocator.free(payload); const frame = try allocator.create(Frame); errdefer allocator.destroy(frame);" ++
        "frame.* = .{ .payload = payload, .other = undefined }; errdefer frame.deinit(allocator); return frame; }";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    for (found) |warning| try std.testing.expect(warning.rule != .double_release);
}

test "conditional errdefer cleanup does not prove an aggregate double release" {
    const source =
        "const Frame = struct { payload: []u8, fn deinit(self: *Frame, allocator: std.mem.Allocator) void {" ++
        "allocator.free(self.payload); allocator.destroy(self); } };" ++
        "fn decode(allocator: std.mem.Allocator) !*Frame { var transferred = false;" ++
        "const payload = try allocator.dupe(u8, \"frame\"); errdefer if (!transferred) allocator.free(payload);" ++
        "const frame = try allocator.create(Frame); errdefer allocator.destroy(frame);" ++
        "frame.* = .{ .payload = payload }; transferred = true; errdefer frame.deinit(allocator); return frame; }";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    for (found) |warning| try std.testing.expect(warning.rule != .double_release);
}

test "declared resource pairs participate in allocation lifecycle proof" {
    var configuration = types.Configuration.defaults();
    configuration.resource_contracts = &.{.{ .acquire = "Db.open", .release = "Db.close" }};
    const leaking_source: [:0]const u8 =
        "fn run() !void { const connection = try Db.open(); _ = connection.id; }";
    const leaking = try warningsWithConfiguration(std.testing.allocator, leaking_source, configuration);
    defer freeWarnings(std.testing.allocator, leaking);
    try std.testing.expectEqual(@as(usize, 1), leaking.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, leaking[0].rule);

    const released_source: [:0]const u8 =
        "fn run() !void { const connection = try Db.open(); defer Db.close(connection); }";
    const released = try warningsWithConfiguration(std.testing.allocator, released_source, configuration);
    defer freeWarnings(std.testing.allocator, released);
    try std.testing.expectEqual(@as(usize, 0), released.len);
}

test "nested aggregate returns transfer every contained allocation" {
    const source =
        "fn init(allocator: std.mem.Allocator) !Owner {" ++
        "const first = try allocator.alloc(u8, 4);" ++
        "errdefer allocator.free(first);" ++
        "const second = try allocator.alloc(u8, 8);" ++
        "errdefer allocator.free(second);" ++
        "return .{ .first = .{ .bytes = first }, .second = .{ .bytes = second } };" ++
        "}";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "inferred owned returns participate in allocation lifecycle proof" {
    const source: [:0]const u8 =
        "fn make(allocator: std.mem.Allocator) ![]u8 { return allocator.alloc(u8, 4); }" ++
        "fn run(allocator: std.mem.Allocator) !void { const bytes = try make(allocator); _ = bytes.len; }";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "owned helper returns backed by a Build parameter use its arena" {
    const source: [:0]const u8 =
        "fn make(b: *std.Build) ![]u8 { return b.allocator.alloc(u8, 4); }" ++
        "fn build(b: *std.Build) !void { const bytes = try make(b); _ = bytes.len; }";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "local method owned returns participate in allocation lifecycle proof" {
    const source: [:0]const u8 =
        "const Packet = struct { fn encode(self: *const Packet, allocator: std.mem.Allocator) ![]u8 { _ = self; return allocator.alloc(u8, 4); } };" ++
        "fn send(allocator: std.mem.Allocator, packet: *const Packet) !void { const bytes = try packet.encode(allocator); _ = bytes.len; }";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "passing a local method allocation to a borrowing method does not transfer ownership" {
    const source: [:0]const u8 =
        "const Packet = struct { fn encode(self: *const Packet, allocator: std.mem.Allocator) ![]u8 { _ = self; return allocator.alloc(u8, 4); } };" ++
        "const Queue = struct { fn decodeAndEnqueue(self: *Queue, bytes: []const u8) !void { _ = self; _ = bytes.len; } };" ++
        "fn send(allocator: std.mem.Allocator, packet: *const Packet, queue: *Queue) !void {" ++
        "const bytes = try packet.encode(allocator); try queue.decodeAndEnqueue(bytes); }";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "writing an owned slice does not transfer its ownership" {
    const source: [:0]const u8 =
        "fn render(allocator: std.mem.Allocator, output: *List) ![]u8 { return output.toOwnedSlice(allocator); }" ++
        "fn write(io: Io, allocator: std.mem.Allocator, output: *List, file: File) !void {" ++
        "const html = try render(allocator, output); try file.writeStreamingAll(io, html); }";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "encoded buffers remain owned after decoder calls" {
    const source: [:0]const u8 =
        "const Packet = struct { payload: []u8, fn encode(self: *const Packet, allocator: std.mem.Allocator) ![]u8 { " ++
        "const encoded = try allocator.alloc(u8, self.payload.len); @memcpy(encoded, self.payload); return encoded; } " ++
        "fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Packet { return .{ .payload = try allocator.dupe(u8, bytes) }; } };" ++
        "const Queue = struct { allocator: std.mem.Allocator, fn decodeAndEnqueue(self: *Queue, bytes: []const u8) !void { " ++
        "_ = try Packet.decode(self.allocator, bytes); } };" ++
        "pub fn main() !void { var debug_allocator = std.heap.DebugAllocator(.{}){}; const allocator = debug_allocator.allocator(); " ++
        "var queue: Queue = undefined; const first: Packet = undefined; const serialized = try first.encode(allocator); " ++
        "try queue.decodeAndEnqueue(serialized); }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]summaries.Source{.{ .file_index = 0, .source = source }};
    const summary_index = try summaries.build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expect(summary_index.ownedReturnCall(source, "first", "encode") != null);
    try std.testing.expectEqual(summaries.ParameterEffect.borrowed, summary_index.parameterEffectForCall(source, "queue.decodeAndEnqueue", 0));
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "owned method returns without allocator provenance accept visible cleanup" {
    const source: [:0]const u8 =
        "const Renderer = struct { fn render(renderer: Renderer, allocator: std.mem.Allocator) ![]u8 { " ++
        "_ = renderer; var writer: Writer = .init(allocator); return writer.toOwnedSlice(); } };" ++
        "fn show(renderer: Renderer) !void { const rendered = try renderer.render(std.testing.allocator); " ++
        "defer std.testing.allocator.free(rendered); }";
    const found = try warnings(std.testing.allocator, source);
    defer freeWarnings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
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
