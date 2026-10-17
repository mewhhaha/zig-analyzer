//! The path walk: whether every path from an allocation's declaration out of
//! its block releases or transfers it, following `if`, `switch`, loops,
//! `break`, `continue`, `return`, `defer` and `errdefer` with a set of
//! ownership states per path.
const std = @import("std");

const syntax_scope = @import("../../../syntax/scope.zig");
const summaries = @import("../../summaries.zig");
const tokenRefersToBinding = @import("../../context.zig").tokenRefersToBinding;
const Allocation = @import("allocation.zig").Allocation;
const scans = @import("scans.zig");
const Cleanup = scans.Cleanup;
const bindingEscapes = scans.bindingEscapes;
const containsBinding = scans.containsBinding;
const enclosingScope = scans.enclosingScope;
const identifierRefersToBinding = scans.identifierRefersToBinding;
const localCallOwnership = scans.localCallOwnership;
const ownershipLeavesScope = scans.ownershipLeavesScope;
const releaseCallContainsBinding = scans.releaseCallContainsBinding;
const releaseUsesAllocationReceiver = scans.releaseUsesAllocationReceiver;
const tokenIsIdentifier = scans.tokenIsIdentifier;
const usesSpan = scans.usesSpan;
const valueTransfersBinding = scans.valueTransfersBinding;
const statement_tables = @import("statement_tables.zig");
const OwnershipCache = statement_tables.OwnershipCache;
const StatementEffects = statement_tables.StatementEffects;
const statementEffects = statement_tables.statementEffects;

pub const ownership_live: u3 = 1 << 0;
pub const ownership_live_with_errdefer: u3 = 1 << 1;
pub const ownership_safe: u3 = 1 << 2;
const ownership_live_states = ownership_live | ownership_live_with_errdefer;

const OwnershipFlow = struct {
    continuing: u3,
    exiting: u3 = 0,
    breaking: u3 = 0,
    repeating: u3 = 0,
};

const OwnershipLoop = struct {
    label: ?[]const u8,
};

pub fn ownershipLeavesAllPaths(
    source: []const u8,
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    declaration_node: std.zig.Ast.Node.Index,
    binding_name: []const u8,
    binding_index: usize,
    allocation: Allocation,
    summary_index: summaries.Index,
    initial_states: u3,
    cache: *OwnershipCache,
) ?Cleanup {
    const declaration_scope = enclosingScope(scope_index, binding_index) orelse return null;
    const block = cache.blockNode(tree, declaration_scope.opening) orelse return null;
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, block) orelse return null;
    const declaration_position = statementPosition(tree, statements, declaration_node) orelse return null;
    const flow = analyzeOwnershipStatements(
        source,
        tree,
        tokens,
        scope_index,
        block,
        statements,
        declaration_position + 1,
        initial_states,
        binding_name,
        binding_index,
        allocation,
        summary_index,
        null,
        cache,
    ) orelse return null;
    const terminal_states = flow.continuing | flow.exiting;
    if (terminal_states == 0) return null;
    return if (terminal_states & ownership_live_states == 0) .released else .missing;
}

/// The position of `statement` in its block's `statements`, which are in
/// source order.
fn statementPosition(
    tree: *const std.zig.Ast,
    statements: []const std.zig.Ast.Node.Index,
    statement: std.zig.Ast.Node.Index,
) ?usize {
    const first_token = tree.firstToken(statement);
    var low: usize = 0;
    var high = statements.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (tree.firstToken(statements[middle]) < first_token) low = middle + 1 else high = middle;
    }
    return if (low < statements.len and statements[low] == statement) low else null;
}

fn analyzeOwnershipStatements(
    source: []const u8,
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    block: std.zig.Ast.Node.Index,
    statements: []const std.zig.Ast.Node.Index,
    first: usize,
    initial_states: u3,
    binding_name: []const u8,
    binding_index: usize,
    allocation: Allocation,
    summary_index: summaries.Index,
    active_loop: ?OwnershipLoop,
    cache: *OwnershipCache,
) ?OwnershipFlow {
    // Outside loops, the statements that do not name the binding are known
    // per block; only the ones that name it, or that stop the walk, need it.
    if (active_loop == null) {
        if (statementEffects(source, tree, tokens, scope_index, block, statements, summary_index, cache)) |effects| {
            return analyzeNamingStatements(
                source,
                tree,
                tokens,
                scope_index,
                effects,
                statements,
                first,
                initial_states,
                binding_name,
                binding_index,
                allocation,
                summary_index,
                cache,
            );
        }
    }
    var flow = OwnershipFlow{ .continuing = initial_states };
    for (statements[first..]) |statement| {
        if (flow.continuing == 0) break;
        const statement_flow = analyzeOwnershipNode(
            source,
            tree,
            tokens,
            scope_index,
            statement,
            flow.continuing,
            binding_name,
            binding_index,
            allocation,
            summary_index,
            active_loop,
            cache,
        ) orelse return null;
        flow.continuing = statement_flow.continuing;
        flow.exiting |= statement_flow.exiting;
        flow.breaking |= statement_flow.breaking;
        flow.repeating |= statement_flow.repeating;
    }
    return flow;
}

/// `analyzeOwnershipStatements` outside loops: runs of statements that do not
/// name the binding pass the states through as `effects` records, so only
/// the statements that name it, or that stop the walk, are walked.
fn analyzeNamingStatements(
    source: []const u8,
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    effects: *const StatementEffects,
    statements: []const std.zig.Ast.Node.Index,
    first: usize,
    initial_states: u3,
    binding_name: []const u8,
    binding_index: usize,
    allocation: Allocation,
    summary_index: summaries.Index,
    cache: *OwnershipCache,
) ?OwnershipFlow {
    var flow = OwnershipFlow{ .continuing = initial_states };
    var position = first;
    while (position < statements.len and flow.continuing != 0) {
        const next = @min(effects.nextNaming(scope_index, binding_name, position), effects.next_stop[position]);
        if (effects.returns_before[next] != effects.returns_before[position]) flow.exiting |= flow.continuing;
        if (effects.errors_before[next] != effects.errors_before[position]) flow.exiting |= statesAfterErrorExit(flow.continuing);
        if (next == statements.len) break;
        const statement_flow = analyzeOwnershipNode(
            source,
            tree,
            tokens,
            scope_index,
            statements[next],
            flow.continuing,
            binding_name,
            binding_index,
            allocation,
            summary_index,
            null,
            cache,
        ) orelse return null;
        flow.continuing = statement_flow.continuing;
        flow.exiting |= statement_flow.exiting;
        flow.breaking |= statement_flow.breaking;
        flow.repeating |= statement_flow.repeating;
        position = next + 1;
    }
    return flow;
}

pub fn analyzeOwnershipNode(
    source: []const u8,
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    node: std.zig.Ast.Node.Index,
    initial_states: u3,
    binding_name: []const u8,
    binding_index: usize,
    allocation: Allocation,
    summary_index: summaries.Index,
    active_loop: ?OwnershipLoop,
    cache: *OwnershipCache,
) ?OwnershipFlow {
    switch (tree.nodeTag(node)) {
        .block_two, .block_two_semicolon, .block, .block_semicolon => {
            var buffer: [2]std.zig.Ast.Node.Index = undefined;
            const statements = tree.blockStatements(&buffer, node) orelse return null;
            return analyzeOwnershipStatements(
                source,
                tree,
                tokens,
                scope_index,
                node,
                statements,
                0,
                initial_states,
                binding_name,
                binding_index,
                allocation,
                summary_index,
                active_loop,
                cache,
            );
        },
        else => {},
    }

    if (tree.fullIf(node)) |conditional| {
        if (conditional.payload_token != null and nodeContainsBinding(
            tree,
            tokens,
            scope_index,
            conditional.ast.cond_expr,
            binding_name,
            binding_index,
        )) return null;
        if (nodeHasAmbiguousOwnershipEffect(
            source,
            tree,
            tokens,
            scope_index,
            conditional.ast.cond_expr,
            binding_name,
            binding_index,
            allocation.release,
            summary_index,
        )) return null;
        const then_flow = analyzeOwnershipNode(
            source,
            tree,
            tokens,
            scope_index,
            conditional.ast.then_expr,
            initial_states,
            binding_name,
            binding_index,
            allocation,
            summary_index,
            active_loop,
            cache,
        ) orelse return null;
        const else_flow = if (conditional.ast.else_expr.unwrap()) |else_node|
            analyzeOwnershipNode(
                source,
                tree,
                tokens,
                scope_index,
                else_node,
                initial_states,
                binding_name,
                binding_index,
                allocation,
                summary_index,
                active_loop,
                cache,
            ) orelse return null
        else
            OwnershipFlow{ .continuing = initial_states };
        var flow = OwnershipFlow{
            .continuing = then_flow.continuing | else_flow.continuing,
            .exiting = then_flow.exiting | else_flow.exiting,
            .breaking = then_flow.breaking | else_flow.breaking,
            .repeating = then_flow.repeating | else_flow.repeating,
        };
        if (nodeContainsTry(tree, tokens, conditional.ast.cond_expr)) flow.exiting |= statesAfterErrorExit(initial_states);
        return flow;
    }

    if (tree.fullSwitch(node)) |selection| {
        if (nodeHasAmbiguousOwnershipEffect(
            source,
            tree,
            tokens,
            scope_index,
            selection.ast.condition,
            binding_name,
            binding_index,
            allocation.release,
            summary_index,
        ) or selection.ast.cases.len == 0) return null;
        var flow = OwnershipFlow{ .continuing = 0 };
        var has_else_case = false;
        for (selection.ast.cases) |case_node| {
            const case = tree.fullSwitchCase(case_node) orelse return null;
            has_else_case = has_else_case or case.ast.values.len == 0;
            const case_flow = analyzeOwnershipNode(
                source,
                tree,
                tokens,
                scope_index,
                case.ast.target_expr,
                initial_states,
                binding_name,
                binding_index,
                allocation,
                summary_index,
                active_loop,
                cache,
            ) orelse return null;
            flow.continuing |= case_flow.continuing;
            flow.exiting |= case_flow.exiting;
            flow.breaking |= case_flow.breaking;
            flow.repeating |= case_flow.repeating;
        }
        if (!has_else_case) return null;
        if (nodeContainsTry(tree, tokens, selection.ast.condition)) flow.exiting |= statesAfterErrorExit(initial_states);
        return flow;
    }

    if (tree.fullWhile(node)) |loop| {
        return analyzeWhileOwnership(
            source,
            tree,
            tokens,
            scope_index,
            loop,
            initial_states,
            binding_name,
            binding_index,
            allocation,
            summary_index,
            active_loop,
            cache,
        );
    }

    if (tree.fullFor(node)) |loop| {
        return analyzeForOwnership(
            source,
            tree,
            tokens,
            scope_index,
            loop,
            initial_states,
            binding_name,
            binding_index,
            allocation,
            summary_index,
            active_loop,
            cache,
        );
    }

    switch (tree.nodeTag(node)) {
        .@"break", .@"continue" => {
            const loop = active_loop orelse return null;
            const label_token, const value_node = tree.nodeData(node).opt_token_and_opt_node;
            if (label_token.unwrap()) |label| {
                const active_label = loop.label orelse return null;
                if (!tokenIsIdentifier(source, tokens[label], active_label)) return null;
            }
            if (tree.nodeTag(node) == .@"continue") {
                if (value_node != .none) return null;
                return .{ .continuing = 0, .repeating = initial_states };
            }
            const states = if (value_node.unwrap()) |value|
                if (nodeTransfersBinding(source, tree, tokens, scope_index, value, binding_name, binding_index))
                    statesAfterOwnershipTransfer(initial_states)
                else
                    initial_states
            else
                initial_states;
            return .{ .continuing = 0, .breaking = states };
        },
        .@"return" => {
            const value = tree.nodeData(node).opt_node.unwrap();
            if (value) |return_value| {
                const contains_try = nodeContainsTry(tree, tokens, return_value);
                const transfers_binding = nodeTransfersBinding(
                    source,
                    tree,
                    tokens,
                    scope_index,
                    return_value,
                    binding_name,
                    binding_index,
                );
                if (contains_try and transfers_binding and aggregateMoveInInitializer(
                    source,
                    tree,
                    tokens,
                    scope_index,
                    return_value,
                    binding_name,
                    binding_index,
                ) != .all_paths) return null;
                if (tree.nodeTag(return_value) == .error_value) {
                    return .{ .continuing = 0, .exiting = statesAfterErrorExit(initial_states) };
                }
                var exits = if (transfers_binding) statesAfterOwnershipTransfer(initial_states) else initial_states;
                if (contains_try) exits |= statesAfterErrorExit(initial_states);
                return .{ .continuing = 0, .exiting = exits };
            }
            return .{ .continuing = 0, .exiting = initial_states };
        },
        .@"defer", .@"errdefer" => {
            const deferred = tree.nodeData(node).node;
            if (!nodeMakesOwnershipSafe(
                source,
                tree,
                tokens,
                scope_index,
                deferred,
                binding_name,
                binding_index,
                allocation,
                summary_index,
                initial_states,
                cache,
            )) return .{ .continuing = initial_states };
            return .{ .continuing = if (tree.nodeTag(node) == .@"defer")
                statesAfterOwnershipTransfer(initial_states)
            else
                statesAfterErrdeferRegistration(initial_states) };
        },
        else => {},
    }

    if (nodeContainsReallocationOfBinding(
        source,
        tree,
        tokens,
        scope_index,
        node,
        binding_name,
        binding_index,
    )) return null;

    var flow = OwnershipFlow{ .continuing = initial_states };
    if (nodeContainsTry(tree, tokens, node)) {
        const ownership_escapes = nodeHasAmbiguousOwnershipEffect(
            source,
            tree,
            tokens,
            scope_index,
            node,
            binding_name,
            binding_index,
            allocation.release,
            summary_index,
        );
        flow.exiting |= if (ownership_escapes)
            statesAfterOwnershipTransfer(initial_states)
        else
            statesAfterErrorExit(initial_states);
    }
    if (nodeMakesOwnershipSafe(
        source,
        tree,
        tokens,
        scope_index,
        node,
        binding_name,
        binding_index,
        allocation,
        summary_index,
        initial_states,
        cache,
    )) flow.continuing = statesAfterOwnershipTransfer(initial_states);
    return flow;
}

fn analyzeWhileOwnership(
    source: []const u8,
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    loop: std.zig.Ast.full.While,
    initial_states: u3,
    binding_name: []const u8,
    binding_index: usize,
    allocation: Allocation,
    summary_index: summaries.Index,
    outer_loop: ?OwnershipLoop,
    cache: *OwnershipCache,
) ?OwnershipFlow {
    if (loop.payload_token != null and nodeContainsBinding(
        tree,
        tokens,
        scope_index,
        loop.ast.cond_expr,
        binding_name,
        binding_index,
    )) return null;
    if (nodeHasAmbiguousOwnershipEffect(
        source,
        tree,
        tokens,
        scope_index,
        loop.ast.cond_expr,
        binding_name,
        binding_index,
        allocation.release,
        summary_index,
    )) return null;

    const current_loop = OwnershipLoop{ .label = if (loop.label_token) |label|
        source[tokens[label].loc.start..tokens[label].loc.end]
    else
        null };
    var header_states = initial_states;
    var exiting_states: u3 = 0;
    var breaking_states: u3 = 0;
    while (true) {
        const body_flow = analyzeOwnershipNode(
            source,
            tree,
            tokens,
            scope_index,
            loop.ast.then_expr,
            header_states,
            binding_name,
            binding_index,
            allocation,
            summary_index,
            current_loop,
            cache,
        ) orelse return null;
        exiting_states |= body_flow.exiting;
        breaking_states |= body_flow.breaking;
        var repeating_states = body_flow.continuing | body_flow.repeating;
        if (loop.ast.cont_expr.unwrap()) |continue_expression| {
            const continue_flow = analyzeOwnershipNode(
                source,
                tree,
                tokens,
                scope_index,
                continue_expression,
                repeating_states,
                binding_name,
                binding_index,
                allocation,
                summary_index,
                current_loop,
                cache,
            ) orelse return null;
            exiting_states |= continue_flow.exiting;
            breaking_states |= continue_flow.breaking;
            repeating_states = continue_flow.continuing | continue_flow.repeating;
        }
        const expanded_header_states = header_states | repeating_states;
        if (expanded_header_states == header_states) break;
        header_states = expanded_header_states;
    }

    if (nodeContainsTry(tree, tokens, loop.ast.cond_expr)) exiting_states |= statesAfterErrorExit(header_states);
    if (nodeIsTrueLiteral(source, tree, tokens, loop.ast.cond_expr)) {
        return .{ .continuing = breaking_states, .exiting = exiting_states };
    }

    const else_flow = if (loop.ast.else_expr.unwrap()) |else_expression|
        analyzeOwnershipNode(
            source,
            tree,
            tokens,
            scope_index,
            else_expression,
            header_states,
            binding_name,
            binding_index,
            allocation,
            summary_index,
            outer_loop,
            cache,
        ) orelse return null
    else
        OwnershipFlow{ .continuing = header_states };
    return .{
        .continuing = breaking_states | else_flow.continuing,
        .exiting = exiting_states | else_flow.exiting,
        .breaking = else_flow.breaking,
        .repeating = else_flow.repeating,
    };
}

fn analyzeForOwnership(
    source: []const u8,
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    loop: std.zig.Ast.full.For,
    initial_states: u3,
    binding_name: []const u8,
    binding_index: usize,
    allocation: Allocation,
    summary_index: summaries.Index,
    outer_loop: ?OwnershipLoop,
    cache: *OwnershipCache,
) ?OwnershipFlow {
    var input_can_fail = false;
    for (loop.ast.inputs) |input| {
        if (nodeHasAmbiguousOwnershipEffect(
            source,
            tree,
            tokens,
            scope_index,
            input,
            binding_name,
            binding_index,
            allocation.release,
            summary_index,
        )) return null;
        input_can_fail = input_can_fail or nodeContainsTry(tree, tokens, input);
    }

    const current_loop = OwnershipLoop{ .label = if (loop.label_token) |label|
        source[tokens[label].loc.start..tokens[label].loc.end]
    else
        null };
    var header_states = initial_states;
    var exiting_states = if (input_can_fail) statesAfterErrorExit(initial_states) else 0;
    var breaking_states: u3 = 0;
    while (true) {
        const body_flow = analyzeOwnershipNode(
            source,
            tree,
            tokens,
            scope_index,
            loop.ast.then_expr,
            header_states,
            binding_name,
            binding_index,
            allocation,
            summary_index,
            current_loop,
            cache,
        ) orelse return null;
        exiting_states |= body_flow.exiting;
        breaking_states |= body_flow.breaking;
        const expanded_header_states = header_states | body_flow.continuing | body_flow.repeating;
        if (expanded_header_states == header_states) break;
        header_states = expanded_header_states;
    }

    const else_flow = if (loop.ast.else_expr.unwrap()) |else_expression|
        analyzeOwnershipNode(
            source,
            tree,
            tokens,
            scope_index,
            else_expression,
            header_states,
            binding_name,
            binding_index,
            allocation,
            summary_index,
            outer_loop,
            cache,
        ) orelse return null
    else
        OwnershipFlow{ .continuing = header_states };
    return .{
        .continuing = breaking_states | else_flow.continuing,
        .exiting = exiting_states | else_flow.exiting,
        .breaking = else_flow.breaking,
        .repeating = else_flow.repeating,
    };
}

fn nodeIsTrueLiteral(source: []const u8, tree: *const std.zig.Ast, tokens: []const std.zig.Token, node: std.zig.Ast.Node.Index) bool {
    const token = tree.firstToken(node);
    return token == tree.lastToken(node) and tokenIsIdentifier(source, tokens[token], "true");
}

fn nodeMakesOwnershipSafe(
    source: []const u8,
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    node: std.zig.Ast.Node.Index,
    binding_name: []const u8,
    binding_index: usize,
    allocation: Allocation,
    summary_index: summaries.Index,
    initial_states: u3,
    cache: *OwnershipCache,
) bool {
    const start: usize = tree.firstToken(node);
    var end = @min(@as(usize, tree.lastToken(node)) + 1, tokens.len);
    if (end < tokens.len and tokens[end].tag == .semicolon) end += 1;
    for (tokens[start..end], start..) |token, method_index| {
        if (token.tag != .identifier or method_index + 1 >= end or tokens[method_index + 1].tag != .l_paren) continue;
        const direct_release = tokenIsIdentifier(source, token, allocation.release) and
            releaseCallContainsBinding(source, tokens, scope_index, binding_name, binding_index, method_index, end) and
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
        if (direct_release or summarized_release) return true;
    }
    if (!nodeContainsBinding(tree, tokens, scope_index, node, binding_name, binding_index)) return false;
    if (tree.fullVarDecl(node)) |declaration| {
        const initializer = declaration.ast.init_node.unwrap() orelse return false;
        if (!nodeContainsBinding(tree, tokens, scope_index, initializer, binding_name, binding_index)) return false;
        switch (aggregateMoveInInitializer(
            source,
            tree,
            tokens,
            scope_index,
            initializer,
            binding_name,
            binding_index,
        )) {
            .all_paths => {
                const destination_index: usize = declaration.ast.mut_token + 1;
                if (destination_index >= tokens.len or tokens[destination_index].tag != .identifier) return false;
                const destination_name = source[tokens[destination_index].loc.start..tokens[destination_index].loc.end];
                if (std.mem.eql(u8, destination_name, "_")) return false;
                return ownershipLeavesAllPaths(
                    source,
                    tree,
                    tokens,
                    scope_index,
                    node,
                    destination_name,
                    destination_index,
                    allocation,
                    summary_index,
                    initial_states,
                    cache,
                ) == .released;
            },
            .some_paths => return false,
            .none => {},
        }
        const initializer_start: usize = tree.firstToken(initializer);
        const initializer_end = @min(@as(usize, tree.lastToken(initializer)) + 1, tokens.len);
        return bindingEscapes(
            source,
            tokens,
            scope_index,
            binding_name,
            binding_index,
            initializer_start,
            initializer_end,
            &usesSpan(scope_index, binding_name, initializer_start, initializer_end),
            allocation.release,
            summary_index,
        );
    }
    return ownershipLeavesScope(
        source,
        tokens,
        scope_index,
        binding_name,
        binding_index,
        start,
        end,
        &usesSpan(scope_index, binding_name, start, end),
        allocation.release,
        summary_index,
    ) == .released;
}

const AggregateMove = enum { none, some_paths, all_paths };

fn aggregateMoveInInitializer(
    source: []const u8,
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    node: std.zig.Ast.Node.Index,
    binding_name: []const u8,
    binding_index: usize,
) AggregateMove {
    switch (tree.nodeTag(node)) {
        .identifier => {
            const index: usize = tree.nodeMainToken(node);
            return if (tokenRefersToBinding(source, tokens, index, binding_name) and
                identifierRefersToBinding(scope_index, binding_index, index)) .all_paths else .none;
        },
        // `bytes.ptr` and `@ptrCast(@alignCast(bytes.ptr))` name the same allocation.
        .field_access => {
            const receiver, const field = tree.nodeData(node).node_and_token;
            if (tree.nodeTag(receiver) != .identifier or !std.mem.eql(u8, tree.tokenSlice(field), "ptr")) return .none;
            return aggregateMoveInInitializer(source, tree, tokens, scope_index, receiver, binding_name, binding_index);
        },
        .builtin_call_two, .builtin_call_two_comma => {
            const builtin = tree.tokenSlice(tree.nodeMainToken(node));
            const pointer_cast = for ([_][]const u8{ "@ptrCast", "@alignCast", "@constCast", "@volatileCast" }) |name| {
                if (std.mem.eql(u8, builtin, name)) break true;
            } else false;
            const argument, const second = tree.nodeData(node).opt_node_and_opt_node;
            if (!pointer_cast or second != .none) return .none;
            const value = argument.unwrap() orelse return .none;
            return aggregateMoveInInitializer(source, tree, tokens, scope_index, value, binding_name, binding_index);
        },
        .struct_init,
        .struct_init_comma,
        .struct_init_dot,
        .struct_init_dot_comma,
        .struct_init_dot_two,
        .struct_init_dot_two_comma,
        .struct_init_one,
        .struct_init_one_comma,
        => return if (structInitializerStoresBinding(
            source,
            tree,
            tokens,
            scope_index,
            node,
            binding_name,
            binding_index,
        )) .all_paths else .none,
        .@"try", .@"nosuspend", .@"comptime" => return aggregateMoveInInitializer(
            source,
            tree,
            tokens,
            scope_index,
            tree.nodeData(node).node,
            binding_name,
            binding_index,
        ),
        .grouped_expression => return aggregateMoveInInitializer(
            source,
            tree,
            tokens,
            scope_index,
            tree.nodeData(node).node_and_token[0],
            binding_name,
            binding_index,
        ),
        else => {},
    }
    if (tree.fullIf(node)) |conditional| {
        if (nodeContainsBinding(
            tree,
            tokens,
            scope_index,
            conditional.ast.cond_expr,
            binding_name,
            binding_index,
        )) return .some_paths;
        const then_move = aggregateMoveInInitializer(
            source,
            tree,
            tokens,
            scope_index,
            conditional.ast.then_expr,
            binding_name,
            binding_index,
        );
        const else_node = conditional.ast.else_expr.unwrap() orelse return if (then_move == .none) .none else .some_paths;
        return mergeAggregateMoves(then_move, aggregateMoveInInitializer(
            source,
            tree,
            tokens,
            scope_index,
            else_node,
            binding_name,
            binding_index,
        ));
    }
    if (tree.fullSwitch(node)) |selection| {
        if (selection.ast.cases.len == 0 or nodeContainsBinding(
            tree,
            tokens,
            scope_index,
            selection.ast.condition,
            binding_name,
            binding_index,
        )) return .some_paths;
        var combined = AggregateMove.all_paths;
        var has_else_case = false;
        for (selection.ast.cases) |case_node| {
            const case = tree.fullSwitchCase(case_node) orelse return .some_paths;
            has_else_case = has_else_case or case.ast.values.len == 0;
            combined = mergeAggregateMoves(combined, aggregateMoveInInitializer(
                source,
                tree,
                tokens,
                scope_index,
                case.ast.target_expr,
                binding_name,
                binding_index,
            ));
        }
        if (!has_else_case and combined != .none) return .some_paths;
        return combined;
    }
    return .none;
}

fn mergeAggregateMoves(left: AggregateMove, right: AggregateMove) AggregateMove {
    if (left == right) return left;
    return .some_paths;
}

fn structInitializerStoresBinding(
    source: []const u8,
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    node: std.zig.Ast.Node.Index,
    binding_name: []const u8,
    binding_index: usize,
) bool {
    const start: usize = tree.firstToken(node);
    const end = @min(@as(usize, tree.lastToken(node)) + 1, tokens.len);
    var uses = scope_index.identifiersNamed(binding_name, start, end);
    while (uses.next()) |index| {
        if (!identifierRefersToBinding(scope_index, binding_index, index)) continue;
        const previous = if (index == start) null else tokens[index - 1].tag;
        // `.bytes = binding.ptr` stores the same allocation as a many-item pointer.
        const value_last = if (index + 3 <= end and tokens[index + 1].tag == .period and
            tokenIsIdentifier(source, tokens[index + 2], "ptr")) index + 2 else index;
        const next = if (value_last + 1 == end) null else tokens[value_last + 1].tag;
        const value_start = previous == null or previous == .equal or previous == .comma or previous == .l_brace;
        const value_end = next == null or next == .comma or next == .r_brace;
        if (value_start and value_end) return true;
    }
    return false;
}

fn nodeContainsReallocationOfBinding(
    source: []const u8,
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    node: std.zig.Ast.Node.Index,
    binding_name: []const u8,
    binding_index: usize,
) bool {
    const start: usize = tree.firstToken(node);
    const end = @min(@as(usize, tree.lastToken(node)) + 1, tokens.len);
    for (tokens[start..end], start..) |token, index| {
        if (!tokenIsIdentifier(source, token, "realloc") or index + 1 >= end or tokens[index + 1].tag != .l_paren) continue;
        const closing = scope_index.matchingToken(index + 1) orelse continue;
        if (closing >= end) continue;
        if (containsBinding(scope_index, binding_name, binding_index, index + 2, closing)) return true;
    }
    return false;
}

fn nodeHasAmbiguousOwnershipEffect(
    source: []const u8,
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    node: std.zig.Ast.Node.Index,
    binding_name: []const u8,
    binding_index: usize,
    release_method: []const u8,
    summary_index: summaries.Index,
) bool {
    if (!nodeContainsBinding(tree, tokens, scope_index, node, binding_name, binding_index)) return false;
    const start: usize = tree.firstToken(node);
    const end = @min(@as(usize, tree.lastToken(node)) + 1, tokens.len);
    return bindingEscapes(
        source,
        tokens,
        scope_index,
        binding_name,
        binding_index,
        start,
        end,
        &usesSpan(scope_index, binding_name, start, end),
        release_method,
        summary_index,
    );
}

fn nodeContainsBinding(
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    node: std.zig.Ast.Node.Index,
    binding_name: []const u8,
    binding_index: usize,
) bool {
    const start: usize = tree.firstToken(node);
    const end = @min(@as(usize, tree.lastToken(node)) + 1, tokens.len);
    return containsBinding(scope_index, binding_name, binding_index, start, end);
}

fn nodeTransfersBinding(
    source: []const u8,
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    node: std.zig.Ast.Node.Index,
    binding_name: []const u8,
    binding_index: usize,
) bool {
    const start: usize = tree.firstToken(node);
    const end = @min(@as(usize, tree.lastToken(node)) + 1, tokens.len);
    return valueTransfersBinding(source, tokens, scope_index, binding_name, binding_index, start, end);
}

fn nodeContainsTry(tree: *const std.zig.Ast, tokens: []const std.zig.Token, node: std.zig.Ast.Node.Index) bool {
    const start: usize = tree.firstToken(node);
    const end = @min(@as(usize, tree.lastToken(node)) + 1, tokens.len);
    for (tokens[start..end]) |token| if (token.tag == .keyword_try) return true;
    return false;
}

fn statesAfterOwnershipTransfer(states: u3) u3 {
    return if (states == 0) 0 else ownership_safe;
}

fn statesAfterErrdeferRegistration(states: u3) u3 {
    var result = states & ownership_safe;
    if (states & ownership_live_states != 0) result |= ownership_live_with_errdefer;
    return result;
}

fn statesAfterErrorExit(states: u3) u3 {
    var result = states & (ownership_live | ownership_safe);
    if (states & ownership_live_with_errdefer != 0) result |= ownership_safe;
    return result;
}
