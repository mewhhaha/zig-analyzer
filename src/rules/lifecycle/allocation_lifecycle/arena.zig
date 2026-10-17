//! Whether an allocation comes from an arena or another allocator that frees
//! everything it handed out at once, so the allocation needs no release of its
//! own: by the allocator's name or declaration, a declared arena-allocator
//! contract, or every caller of the function passing such an allocator.
const std = @import("std");

const syntax_scope = @import("../../../syntax/scope.zig");
const summaries = @import("../../summaries.zig");
const TokenRange = @import("../../../syntax/tokens.zig").Range;
const tokenIsIdentifier = @import("scans.zig").tokenIsIdentifier;

pub fn valueReceivesBuildArena(
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

const arena_backed_types = [_][]const u8{ "ArenaAllocator", "FixedBufferAllocator" };
/// Allocators that serve from a buffer and hand larger requests to a fallback.
const buffer_first_types = [_][]const u8{ "BufferFirstAllocator", "StackFallbackAllocator", "stackFallback" };

pub fn allocatorIsArenaBacked(declarations: *DeclarationsByName, allocator_name: []const u8) !bool {
    const source = declarations.source;
    const tokens = declarations.tokens;
    const allocator_method = ".allocator()";
    var name = if (std.mem.endsWith(u8, allocator_name, allocator_method))
        allocator_name[0 .. allocator_name.len - allocator_method.len]
    else
        allocator_name;
    for (0..4) |_| {
        const declaration = try declarations.firstValue(name) orelse return false;
        var buffer_first = false;
        var names_arena = false;
        for (tokens[declaration.start..declaration.end]) |token| {
            if (token.tag != .identifier) continue;
            const text = source[token.loc.start..token.loc.end];
            for (arena_backed_types) |arena_type| if (std.mem.eql(u8, text, arena_type)) return true;
            for (buffer_first_types) |buffer_type| buffer_first = buffer_first or std.mem.eql(u8, text, buffer_type);
            names_arena = names_arena or std.ascii.findIgnoreCase(text, "arena") != null;
        }
        // A stack buffer that falls back to an arena frees nothing on its own.
        if (buffer_first and names_arena) return true;
        name = allocatorCallReceiver(source, tokens, declaration) orelse return false;
    }
    return false;
}

pub fn allocatorMatchesArenaContract(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    use_index: usize,
    allocator_source: []const u8,
    allocator_member: ?[]const u8,
    contracts: []const []const u8,
) bool {
    const receiver_name, const field_name = if (allocator_member) |member|
        .{ allocator_source, member }
    else provider: {
        const provider = std.mem.trimEnd(u8, allocator_source, "()");
        const separator = std.mem.findScalar(u8, provider, '.') orelse return false;
        break :provider .{ provider[0..separator], provider[separator + 1 ..] };
    };
    const binding = scope_index.findBindingNamed(receiver_name, use_index) orelse return false;
    const type_name = declaredBindingTypeName(source, tokens, binding.token_index) orelse return false;

    for (contracts) |contract| {
        const contract_separator = std.mem.findScalar(u8, contract, '.') orelse continue;
        if (!std.mem.eql(u8, field_name, contract[contract_separator + 1 ..])) continue;
        const owner_type = contract[0..contract_separator];
        if (std.mem.eql(u8, type_name, owner_type)) return true;
    }
    return false;
}

fn declaredBindingTypeName(
    source: []const u8,
    tokens: []const std.zig.Token,
    binding_index: usize,
) ?[]const u8 {
    if (binding_index + 2 >= tokens.len or tokens[binding_index + 1].tag != .colon) return null;
    var type_name: ?[]const u8 = null;
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    for (tokens[binding_index + 2 ..]) |token| {
        switch (token.tag) {
            .l_paren => parenthesis_depth += 1,
            .r_paren => {
                if (parenthesis_depth == 0 and bracket_depth == 0) break;
                parenthesis_depth -|= 1;
            },
            .l_bracket => bracket_depth += 1,
            .r_bracket => bracket_depth -|= 1,
            .equal, .comma => if (parenthesis_depth == 0 and bracket_depth == 0) break,
            .identifier => type_name = source[token.loc.start..token.loc.end],
            else => {},
        }
    }
    return type_name;
}

pub fn allocatorParameterIsAlwaysArenaBacked(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    declarations: *DeclarationsByName,
    declaration_index: usize,
    allocator_name: []const u8,
    summary_index: summaries.Index,
) !bool {
    const function = summary_index.functionContaining(source, declaration_index) orelse return false;
    const parameter_index = for (function.parameter_names, 0..) |parameter, index| {
        if (std.mem.eql(u8, parameter, allocator_name)) break index;
    } else return false;

    var call_chain: [16]usize = undefined;
    return parameterIsAlwaysArenaBacked(
        source,
        tokens,
        scope_index,
        declarations,
        function,
        parameter_index,
        summary_index,
        &call_chain,
        0,
    );
}

fn parameterIsAlwaysArenaBacked(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    declarations: *DeclarationsByName,
    function: summaries.FunctionSummary,
    parameter_index: usize,
    summary_index: summaries.Index,
    call_chain: *[16]usize,
    call_depth: usize,
) !bool {
    if (summaries.parameterDocumentsArena(function, function.parameter_names[parameter_index])) return true;
    if (functionParameterMatchesArenaContract(
        function,
        function.parameter_names[parameter_index],
        summary_index.arena_allocator_contracts,
    )) return true;
    if (function.externally_visible) return false;
    if (call_depth == call_chain.len) return false;
    for (call_chain[0..call_depth]) |body_start| if (body_start == function.body_start) return false;
    call_chain[call_depth] = function.body_start;
    var found_call = false;
    var uses = scope_index.identifiersNamed(function.name, 0, tokens.len);
    while (uses.next()) |index| {
        if (index > 0 and tokens[index - 1].tag == .keyword_fn) continue;
        if (index > 0 and tokens[index - 1].tag == .period) continue;
        if (index + 1 >= tokens.len or tokens[index + 1].tag != .l_paren) return false;
        const closing = scope_index.matchingToken(index + 1) orelse return false;
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
                break :arena_backed std.ascii.findIgnoreCase(receiver, "arena") != null or
                    try allocatorIsArenaBacked(declarations, receiver);
            }
            if (argument.start + 1 != argument.end or tokens[argument.start].tag != .identifier) {
                break :arena_backed false;
            }
            const argument_name = source[tokens[argument.start].loc.start..tokens[argument.start].loc.end];
            break :arena_backed std.ascii.findIgnoreCase(argument_name, "arena") != null or
                try allocatorIsArenaBacked(declarations, argument_name);
        };
        if (!arena_backed) {
            if (argument.start + 1 != argument.end or tokens[argument.start].tag != .identifier) return false;
            const caller = summary_index.functionContaining(source, index) orelse return false;
            const argument_name = source[tokens[argument.start].loc.start..tokens[argument.start].loc.end];
            const caller_parameter = for (caller.parameter_names, 0..) |parameter, caller_index| {
                if (std.mem.eql(u8, parameter, argument_name)) break caller_index;
            } else return false;
            if (!try parameterIsAlwaysArenaBacked(
                source,
                tokens,
                scope_index,
                declarations,
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

fn functionParameterMatchesArenaContract(
    function: summaries.FunctionSummary,
    parameter_name: []const u8,
    contracts: []const []const u8,
) bool {
    for (contracts) |contract| {
        const separator = std.mem.findScalar(u8, contract, '.') orelse continue;
        if (!std.mem.eql(u8, parameter_name, contract[separator + 1 ..])) continue;
        const function_name = contract[0..separator];
        if (std.mem.eql(u8, function.name, function_name)) return true;
    }
    return false;
}

/// The `const` and `var` declarations of a file by name, found in one pass
/// the first time an allocator's declaration is looked up.
pub const DeclarationsByName = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    /// The `const`/`var` keyword of each declaration, in order.
    positions: ?std.StringHashMapUnmanaged(std.ArrayList(u32)) = null,

    pub fn deinit(declarations: *DeclarationsByName) void {
        var positions = declarations.positions orelse return;
        var lists = positions.valueIterator();
        while (lists.next()) |list| list.deinit(declarations.allocator);
        positions.deinit(declarations.allocator);
    }

    /// The value of the first declaration of `name` in the file that ends.
    fn firstValue(declarations: *DeclarationsByName, name: []const u8) !?TokenRange {
        const tokens = declarations.tokens;
        if (declarations.positions == null) {
            var positions: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty;
            errdefer {
                var lists = positions.valueIterator();
                while (lists.next()) |list| list.deinit(declarations.allocator);
                positions.deinit(declarations.allocator);
            }
            for (tokens, 0..) |token, index| {
                if ((token.tag != .keyword_const and token.tag != .keyword_var) or index + 2 >= tokens.len or
                    tokens[index + 1].tag != .identifier) continue;
                const entry = try positions.getOrPut(declarations.allocator, declarations.source[tokens[index + 1].loc.start..tokens[index + 1].loc.end]);
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(declarations.allocator, @intCast(index));
            }
            declarations.positions = positions;
        }
        const list = declarations.positions.?.get(name) orelse return null;
        for (list.items) |position| {
            const index: usize = position;
            const end = findStatementEnd(tokens, index) orelse continue;
            return .{ .start = index + 2, .end = end };
        }
        return null;
    }
};

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
