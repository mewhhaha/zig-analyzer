const std = @import("std");

pub const BindingKind = enum {
    callable,
    non_callable,
    unknown,
};

pub const Binding = struct {
    token_index: usize,
    scope: std.zig.Token.Loc,
    kind: BindingKind,
    alias_target: ?[]const u8 = null,
    scope_rank: usize = 0,
};

const LexicalScope = struct {
    opening: ?usize,
    closing: usize,
};

pub const Index = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    bindings: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Binding)) = .empty,
    usingnamespace_scopes: std.ArrayListUnmanaged(std.zig.Token.Loc) = .empty,
    matching_tokens: []?usize = &.{},
    enclosing_braces: []?usize = &.{},

    pub fn init(
        allocator: std.mem.Allocator,
        source: []const u8,
        tokens: []const std.zig.Token,
    ) !Index {
        var index: Index = .{ .allocator = allocator, .source = source, .tokens = tokens };
        errdefer index.deinit();
        var scope_openings: std.ArrayListUnmanaged(usize) = .empty;
        defer scope_openings.deinit(allocator);
        var parenthesis_openings: std.ArrayListUnmanaged(usize) = .empty;
        defer parenthesis_openings.deinit(allocator);
        var bracket_openings: std.ArrayListUnmanaged(usize) = .empty;
        defer bracket_openings.deinit(allocator);
        index.matching_tokens = try allocator.alloc(?usize, tokens.len);
        @memset(index.matching_tokens, null);
        index.enclosing_braces = try allocator.alloc(?usize, tokens.len);
        @memset(index.enclosing_braces, null);
        for (tokens, 0..) |token, token_index| switch (token.tag) {
            .l_brace => try scope_openings.append(allocator, token_index),
            .r_brace => if (scope_openings.pop()) |opening| {
                index.matching_tokens[opening] = token_index;
                index.matching_tokens[token_index] = opening;
            },
            .l_paren => try parenthesis_openings.append(allocator, token_index),
            .r_paren => if (parenthesis_openings.pop()) |opening| {
                index.matching_tokens[opening] = token_index;
                index.matching_tokens[token_index] = opening;
            },
            .l_bracket => try bracket_openings.append(allocator, token_index),
            .r_bracket => if (bracket_openings.pop()) |opening| {
                index.matching_tokens[opening] = token_index;
                index.matching_tokens[token_index] = opening;
            },
            else => {},
        };
        scope_openings.clearRetainingCapacity();
        for (tokens, 0..) |token, token_index| {
            if (token.tag == .r_brace) _ = scope_openings.pop();
            index.enclosing_braces[token_index] = scope_openings.getLastOrNull();
            if (token.tag == .identifier) {
                const lexical_scope: LexicalScope = if (scope_openings.getLastOrNull()) |opening|
                    .{ .opening = opening, .closing = index.matching_tokens[opening] orelse tokens.len - 1 }
                else
                    .{ .opening = null, .closing = tokens.len - 1 };
                if (binding(tokens, source, token_index, lexical_scope)) |unindexed_candidate| {
                    var candidate = unindexed_candidate;
                    candidate.alias_target = aliasTarget(source, tokens, token_index);
                    candidate.scope_rank = if (scope_openings.getLastOrNull()) |opening| opening + 1 else 0;
                    const entry = try index.bindings.getOrPut(allocator, tokenText(source, token));
                    if (!entry.found_existing) entry.value_ptr.* = .empty;
                    try entry.value_ptr.append(allocator, candidate);
                }
            }
            if (std.mem.eql(u8, tokenText(source, token), "usingnamespace")) {
                const lexical_scope: LexicalScope = if (scope_openings.getLastOrNull()) |opening|
                    .{ .opening = opening, .closing = index.matching_tokens[opening] orelse tokens.len - 1 }
                else
                    .{ .opening = null, .closing = tokens.len - 1 };
                const scope = declarationScope(tokens, token_index, true, lexical_scope) orelse continue;
                try index.usingnamespace_scopes.append(allocator, scope);
            }
            if (token.tag == .l_brace) try scope_openings.append(allocator, token_index);
        }
        var binding_lists = index.bindings.valueIterator();
        while (binding_lists.next()) |bindings| {
            std.mem.sort(Binding, bindings.items, {}, struct {
                fn lessThan(_: void, left: Binding, right: Binding) bool {
                    if (left.scope.start != right.scope.start) return left.scope.start < right.scope.start;
                    if (left.scope.end != right.scope.end) return left.scope.end > right.scope.end;
                    return left.token_index < right.token_index;
                }
            }.lessThan);
        }
        return index;
    }

    pub fn deinit(index: *Index) void {
        var iterator = index.bindings.valueIterator();
        while (iterator.next()) |bindings| bindings.deinit(index.allocator);
        index.bindings.deinit(index.allocator);
        index.usingnamespace_scopes.deinit(index.allocator);
        index.allocator.free(index.matching_tokens);
        index.allocator.free(index.enclosing_braces);
    }

    pub fn findBinding(index: *const Index, use_index: usize) ?Binding {
        if (use_index >= index.tokens.len or index.tokens[use_index].tag != .identifier) return null;
        return index.findBindingNamed(tokenText(index.source, index.tokens[use_index]), use_index);
    }

    pub fn findBindingNamed(index: *const Index, name: []const u8, use_index: usize) ?Binding {
        if (use_index >= index.tokens.len) return null;
        const candidates = index.bindings.get(name) orelse return null;
        const occurrence = index.tokens[use_index].loc;
        var low: usize = 0;
        var high = candidates.items.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (candidates.items[middle].scope.start <= occurrence.start)
                low = middle + 1
            else
                high = middle;
        }
        var cursor = low;
        while (cursor > 0) {
            cursor -= 1;
            const candidate = candidates.items[cursor];
            if (spanContains(candidate.scope, occurrence)) return candidate;
        }
        return null;
    }

    pub fn usingnamespaceMayProvideName(index: *const Index, use_index: usize) bool {
        if (use_index >= index.tokens.len) return false;
        for (index.usingnamespace_scopes.items) |scope| {
            if (spanContains(scope, index.tokens[use_index].loc)) return true;
        }
        return false;
    }

    pub fn matchingToken(index: *const Index, opening_index: usize) ?usize {
        if (opening_index >= index.matching_tokens.len) return null;
        return index.matching_tokens[opening_index];
    }

    pub fn enclosingScopeEnd(index: *const Index, token_index: usize) ?usize {
        if (token_index >= index.enclosing_braces.len) return null;
        const opening = index.enclosing_braces[token_index] orelse return null;
        return index.matchingToken(opening);
    }

    pub fn statementEnd(index: *const Index, start: usize) ?usize {
        var cursor = start;
        while (cursor < index.tokens.len) {
            switch (index.tokens[cursor].tag) {
                .l_paren, .l_bracket, .l_brace => cursor = index.matchingToken(cursor) orelse return null,
                .r_brace => return null,
                .semicolon => return cursor,
                else => {},
            }
            cursor += 1;
        }
        return null;
    }
};

fn aliasTarget(source: []const u8, tokens: []const std.zig.Token, identifier_index: usize) ?[]const u8 {
    if (identifier_index + 3 >= tokens.len or tokens[identifier_index + 1].tag != .equal or
        tokens[identifier_index + 2].tag != .identifier or tokens[identifier_index + 3].tag != .semicolon) return null;
    return tokenText(source, tokens[identifier_index + 2]);
}

pub fn findBinding(
    source: []const u8,
    tokens: []const std.zig.Token,
    use_index: usize,
) ?Binding {
    if (use_index >= tokens.len or tokens[use_index].tag != .identifier) return null;
    const name = tokenText(source, tokens[use_index]);
    var selected: ?Binding = null;
    for (tokens, 0..) |token, candidate_index| {
        if (token.tag != .identifier or !std.mem.eql(u8, tokenText(source, token), name)) continue;
        const candidate = binding(tokens, source, candidate_index, null) orelse continue;
        if (!spanContains(candidate.scope, tokens[use_index].loc)) continue;
        if (selected == null or scopeLength(candidate.scope) < scopeLength(selected.?.scope) or
            scopeLength(candidate.scope) == scopeLength(selected.?.scope) and
                candidate.token_index > selected.?.token_index)
        {
            selected = candidate;
        }
    }
    return selected;
}

pub fn declarationAt(
    source: []const u8,
    tokens: []const std.zig.Token,
    identifier_index: usize,
) ?Binding {
    if (identifier_index >= tokens.len or tokens[identifier_index].tag != .identifier) return null;
    return binding(tokens, source, identifier_index, null);
}

pub fn isContainerFieldDeclaration(tokens: []const std.zig.Token, identifier_index: usize) bool {
    if (identifier_index == 0 or identifier_index >= tokens.len or tokens[identifier_index].tag != .identifier or
        identifier_index + 1 >= tokens.len) return false;
    switch (tokens[identifier_index - 1].tag) {
        .l_brace, .r_brace, .comma, .semicolon, .doc_comment, .container_doc_comment => {},
        else => return false,
    }
    const opening = enclosingOpeningBrace(tokens, identifier_index) orelse return false;
    if (!braceStartsContainer(tokens, opening)) return false;
    return switch (tokens[identifier_index + 1].tag) {
        .colon, .comma, .equal, .r_brace => true,
        else => false,
    };
}

pub fn usingnamespaceMayProvideName(source: []const u8, tokens: []const std.zig.Token, use_index: usize) bool {
    if (use_index >= tokens.len) return false;
    for (tokens, 0..) |token, index| {
        if (!std.mem.eql(u8, tokenText(source, token), "usingnamespace")) continue;
        const scope = declarationScope(tokens, index, true, null) orelse continue;
        if (spanContains(scope, tokens[use_index].loc)) return true;
    }
    return false;
}

fn binding(
    tokens: []const std.zig.Token,
    source: []const u8,
    identifier_index: usize,
    lexical_scope: ?LexicalScope,
) ?Binding {
    if (identifierIsNamedDeclaration(tokens, identifier_index)) {
        const declaration_tag = tokens[identifier_index - 1].tag;
        const container_member = if (lexical_scope) |scope|
            if (scope.opening) |opening| braceStartsContainer(tokens, opening) else true
        else
            declarationIsContainerMember(tokens, identifier_index - 1);
        return .{
            .token_index = identifier_index,
            .scope = declarationScope(tokens, identifier_index - 1, container_member, lexical_scope) orelse return null,
            .kind = if (declaration_tag == .keyword_fn)
                .callable
            else
                initializerKind(source, tokens, identifier_index),
        };
    }
    if (identifierIsFunctionParameter(tokens, identifier_index)) {
        const body = functionBodyAfterParameter(tokens, identifier_index) orelse return null;
        const closing = matchingToken(tokens, body, .l_brace, .r_brace) orelse return null;
        return .{
            .token_index = identifier_index,
            .scope = .{ .start = tokens[identifier_index].loc.end, .end = tokens[closing].loc.end },
            .kind = .unknown,
        };
    }
    if (identifierIsCapture(tokens, identifier_index)) {
        const scope = captureScope(tokens, identifier_index) orelse return null;
        return .{ .token_index = identifier_index, .scope = scope, .kind = .unknown };
    }
    if (identifierIsDestructureBinding(tokens, identifier_index)) {
        const declaration_index = destructureDeclarationIndex(tokens, identifier_index) orelse return null;
        var scope = declarationScope(tokens, declaration_index, false, null) orelse return null;
        scope.start = tokens[identifier_index].loc.end;
        return .{
            .token_index = identifier_index,
            .scope = scope,
            .kind = .unknown,
        };
    }
    return null;
}

fn identifierIsNamedDeclaration(tokens: []const std.zig.Token, index: usize) bool {
    if (index == 0 or index + 1 >= tokens.len) return false;
    return switch (tokens[index - 1].tag) {
        .keyword_fn => tokens[index + 1].tag == .l_paren,
        .keyword_const, .keyword_var => switch (tokens[index + 1].tag) {
            .equal, .colon, .keyword_align, .keyword_addrspace, .keyword_linksection => true,
            else => false,
        } and
            declarationKeywordStartsStatement(tokens, index - 1),
        else => false,
    };
}

fn declarationKeywordStartsStatement(tokens: []const std.zig.Token, index: usize) bool {
    if (index == 0) return true;
    if (index >= 2 and tokens[index - 1].tag == .string_literal and tokens[index - 2].tag == .keyword_extern) return true;
    return switch (tokens[index - 1].tag) {
        .l_brace,
        .r_brace,
        .comma,
        .semicolon,
        .doc_comment,
        .container_doc_comment,
        .keyword_pub,
        .keyword_export,
        .keyword_extern,
        .keyword_inline,
        .keyword_noinline,
        .keyword_comptime,
        .keyword_threadlocal,
        => true,
        else => false,
    };
}

fn declarationIsContainerMember(tokens: []const std.zig.Token, keyword_index: usize) bool {
    const opening = enclosingOpeningBrace(tokens, keyword_index) orelse return true;
    return braceStartsContainer(tokens, opening);
}

fn braceStartsContainer(tokens: []const std.zig.Token, opening: usize) bool {
    var cursor = opening;
    var parenthesis_depth: usize = 0;
    while (cursor > 0 and opening - cursor < 32) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .r_paren => parenthesis_depth += 1,
            .l_paren => parenthesis_depth -|= 1,
            .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => if (parenthesis_depth == 0) return true,
            .equal => if (parenthesis_depth == 0) return false,
            .semicolon, .l_brace, .r_brace => if (parenthesis_depth == 0) return false,
            else => {},
        }
    }
    return false;
}

fn declarationScope(
    tokens: []const std.zig.Token,
    declaration_index: usize,
    order_independent: bool,
    lexical_scope: ?LexicalScope,
) ?std.zig.Token.Loc {
    if (lexical_scope) |scope| return .{
        .start = if (order_independent)
            if (scope.opening) |opening| tokens[opening].loc.end else 0
        else
            tokens[declaration_index].loc.end,
        .end = tokens[scope.closing].loc.end,
    };
    const opening = enclosingOpeningBrace(tokens, declaration_index);
    const closing = if (opening) |brace|
        matchingToken(tokens, brace, .l_brace, .r_brace) orelse return null
    else
        tokens.len - 1;
    return .{
        .start = if (order_independent)
            if (opening) |brace| tokens[brace].loc.end else 0
        else
            tokens[declaration_index].loc.end,
        .end = tokens[closing].loc.end,
    };
}

fn identifierIsFunctionParameter(tokens: []const std.zig.Token, index: usize) bool {
    if (index + 1 >= tokens.len or tokens[index + 1].tag != .colon) return false;
    const opening = enclosingOpeningParenthesis(tokens, index) orelse return false;
    if (opening < 2 or tokens[opening - 1].tag != .identifier or tokens[opening - 2].tag != .keyword_fn) return false;
    const closing = matchingToken(tokens, opening, .l_paren, .r_paren) orelse return false;
    return index < closing;
}

fn functionBodyAfterParameter(tokens: []const std.zig.Token, index: usize) ?usize {
    const opening = enclosingOpeningParenthesis(tokens, index) orelse return null;
    const closing = matchingToken(tokens, opening, .l_paren, .r_paren) orelse return null;
    return functionBodyAfterParameters(tokens, closing);
}

pub fn functionBodyAfterParameters(tokens: []const std.zig.Token, parameters_end: usize) ?usize {
    if (parameters_end >= tokens.len or tokens[parameters_end].tag != .r_paren) return null;
    var cursor = parameters_end + 1;
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    while (cursor < tokens.len) : (cursor += 1) {
        switch (tokens[cursor].tag) {
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .l_bracket => bracket_depth += 1,
            .r_bracket => bracket_depth -|= 1,
            .l_brace => if (parenthesis_depth == 0 and bracket_depth == 0) {
                if (!braceStartsReturnType(tokens, cursor, parameters_end + 1)) return cursor;
                cursor = matchingToken(tokens, cursor, .l_brace, .r_brace) orelse return null;
            },
            .comma, .semicolon => if (parenthesis_depth == 0 and bracket_depth == 0) return null,
            else => {},
        }
    }
    return null;
}

fn braceStartsReturnType(tokens: []const std.zig.Token, opening: usize, return_type_start: usize) bool {
    var cursor = opening;
    while (cursor > return_type_start) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .colon,
            .keyword_error,
            .keyword_struct,
            .keyword_union,
            .keyword_enum,
            .keyword_opaque,
            .keyword_switch,
            .keyword_if,
            => return true,
            .bang, .question_mark, .asterisk, .asterisk_asterisk, .identifier, .builtin, .l_paren, .r_paren, .comma => {},
            else => return false,
        }
    }
    return false;
}

fn identifierIsCapture(tokens: []const std.zig.Token, index: usize) bool {
    var opening = index;
    while (opening > 0 and index - opening < 16) {
        opening -= 1;
        switch (tokens[opening].tag) {
            .pipe => break,
            .identifier, .asterisk, .comma => {},
            else => return false,
        }
    } else return false;
    var closing = index + 1;
    while (closing < tokens.len and closing - index < 16) : (closing += 1) switch (tokens[closing].tag) {
        .pipe => return true,
        .identifier, .asterisk, .comma => {},
        else => return false,
    };
    return false;
}

fn captureScope(tokens: []const std.zig.Token, index: usize) ?std.zig.Token.Loc {
    var closing_pipe = index + 1;
    while (closing_pipe < tokens.len and tokens[closing_pipe].tag != .pipe) : (closing_pipe += 1) {}
    if (closing_pipe == tokens.len) return null;
    const body = closing_pipe + 1;
    if (body >= tokens.len) return null;
    const end = if (tokens[body].tag == .l_brace)
        matchingToken(tokens, body, .l_brace, .r_brace) orelse return null
    else
        expressionEnd(tokens, body) orelse return null;
    return .{ .start = tokens[body].loc.start, .end = tokens[end].loc.end };
}

fn identifierIsDestructureBinding(tokens: []const std.zig.Token, index: usize) bool {
    return destructureDeclarationIndex(tokens, index) != null;
}

fn destructureDeclarationIndex(tokens: []const std.zig.Token, index: usize) ?usize {
    var cursor = index;
    var nested_braces: usize = 0;
    var declaration_index: ?usize = null;
    while (cursor > 0 and index - cursor < 64) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .keyword_const, .keyword_var => {
                declaration_index = cursor;
                break;
            },
            .l_brace => nested_braces += 1,
            .equal, .semicolon, .r_brace => return null,
            else => {},
        }
    }
    if (declaration_index == null) return null;
    cursor = index + 1;
    while (cursor < tokens.len and cursor - index < 64) : (cursor += 1) switch (tokens[cursor].tag) {
        .equal => return if (nested_braces != 0 or index > 0 and
            (tokens[index - 1].tag == .keyword_const or tokens[index - 1].tag == .keyword_var)) declaration_index else null,
        .semicolon => return null,
        else => {},
    };
    return null;
}

fn initializerKind(source: []const u8, tokens: []const std.zig.Token, identifier_index: usize) BindingKind {
    if (identifier_index + 2 >= tokens.len or tokens[identifier_index + 1].tag != .equal) return .unknown;
    const initializer = tokens[identifier_index + 2];
    return switch (initializer.tag) {
        .number_literal, .string_literal, .char_literal, .multiline_string_literal_line => .non_callable,
        .identifier => if (std.mem.eql(u8, tokenText(source, initializer), "true") or
            std.mem.eql(u8, tokenText(source, initializer), "false") or
            std.mem.eql(u8, tokenText(source, initializer), "null") or
            std.mem.eql(u8, tokenText(source, initializer), "undefined")) .non_callable else .unknown,
        .period => .non_callable,
        else => .unknown,
    };
}

fn enclosingOpeningBrace(tokens: []const std.zig.Token, index: usize) ?usize {
    var depth: usize = 0;
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .r_brace => depth += 1,
            .l_brace => {
                if (depth == 0) return cursor;
                depth -= 1;
            },
            else => {},
        }
    }
    return null;
}

fn enclosingOpeningParenthesis(tokens: []const std.zig.Token, index: usize) ?usize {
    var parenthesis_depth: usize = 0;
    var brace_depth: usize = 0;
    var bracket_depth: usize = 0;
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .r_paren => parenthesis_depth += 1,
            .l_paren => {
                if (parenthesis_depth == 0 and brace_depth == 0 and bracket_depth == 0) return cursor;
                parenthesis_depth -|= 1;
            },
            .r_brace => brace_depth += 1,
            .l_brace => {
                if (brace_depth == 0) return null;
                brace_depth -= 1;
            },
            .r_bracket => bracket_depth += 1,
            .l_bracket => bracket_depth -|= 1,
            .semicolon => if (parenthesis_depth == 0 and brace_depth == 0 and bracket_depth == 0) return null,
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

fn expressionEnd(tokens: []const std.zig.Token, start: usize) ?usize {
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    var inside_capture = false;
    for (tokens[start..], start..) |token, index| switch (token.tag) {
        .l_paren => parenthesis_depth += 1,
        .r_paren => {
            if (parenthesis_depth == 0) return index -| 1;
            parenthesis_depth -= 1;
        },
        .l_bracket => bracket_depth += 1,
        .r_bracket => bracket_depth -|= 1,
        .l_brace => brace_depth += 1,
        .r_brace => {
            if (brace_depth == 0) return index -| 1;
            brace_depth -= 1;
        },
        .pipe => inside_capture = !inside_capture,
        .semicolon => if (!inside_capture and parenthesis_depth == 0 and bracket_depth == 0 and brace_depth == 0) return index -| 1,
        .comma => if (!inside_capture and parenthesis_depth == 0 and bracket_depth == 0 and brace_depth == 0 and
            !commaContinuesDestructuringAssignment(tokens, index)) return index -| 1,
        else => {},
    };
    return null;
}

fn commaContinuesDestructuringAssignment(tokens: []const std.zig.Token, comma_index: usize) bool {
    for (tokens[comma_index + 1 ..]) |token| switch (token.tag) {
        .equal => return true,
        .semicolon, .l_brace, .r_brace => return false,
        else => {},
    };
    return false;
}

fn spanContains(scope: std.zig.Token.Loc, occurrence: std.zig.Token.Loc) bool {
    return occurrence.start >= scope.start and occurrence.end <= scope.end;
}

fn scopeLength(scope: std.zig.Token.Loc) usize {
    return scope.end -| scope.start;
}

fn tokenText(source: []const u8, token: std.zig.Token) []const u8 {
    return source[token.loc.start..token.loc.end];
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]const std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    errdefer tokens.deinit(allocator);
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        try tokens.append(allocator, token);
        if (token.tag == .eof) break;
    }
    return try tokens.toOwnedSlice(allocator);
}

test "bindings respect lexical scopes and local declaration order" {
    const source: [:0]const u8 =
        "const global = 1;\n" ++
        "fn first(arg: u8) void { _ = global; _ = arg; _ = later; _ = foreign; const later = 1; }\n" ++
        "fn second() void { const foreign = 1; }\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    var later_use: ?usize = null;
    var foreign_use: ?usize = null;
    for (tokens, 0..) |token, index| {
        if (later_use == null and token.loc.start >= std.mem.indexOf(u8, source, "_ = later").? and std.mem.eql(u8, tokenText(source, token), "later")) later_use = index;
        if (token.loc.start >= std.mem.indexOf(u8, source, "_ = foreign").? and token.loc.start < std.mem.indexOf(u8, source, "fn second").? and std.mem.eql(u8, tokenText(source, token), "foreign")) foreign_use = index;
    }
    try std.testing.expect(findBinding(source, tokens, later_use.?) == null);
    try std.testing.expect(findBinding(source, tokens, foreign_use.?) == null);
}

test "indexed bindings select the innermost alias" {
    const source: [:0]const u8 =
        "const Alias = Global;\n" ++
        "fn run() void { const Alias = Local; _ = Alias; }\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    var index = try Index.init(std.testing.allocator, source, tokens);
    defer index.deinit();

    const use_start = std.mem.indexOf(u8, source, "_ = Alias").?;
    var use_index: ?usize = null;
    for (tokens, 0..) |token, token_index| {
        if (token.loc.start >= use_start and std.mem.eql(u8, tokenText(source, token), "Alias")) {
            use_index = token_index;
            break;
        }
    }
    try std.testing.expect(use_index != null);
    const selected = index.findBinding(use_index.?);
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("Local", selected.?.alias_target.?);
    try std.testing.expect(selected.?.scope_rank != 0);
}

test "structural index resolves delimiters statements and enclosing scopes" {
    const source: [:0]const u8 = "fn run(values: []u8) void { const value = call(values[0]); _ = value; }\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    var index = try Index.init(std.testing.allocator, source, tokens);
    defer index.deinit();

    var declaration_index: ?usize = null;
    var call_opening: ?usize = null;
    for (tokens, 0..) |token, token_index| {
        if (token.tag == .keyword_const) declaration_index = token_index;
        if (token.tag == .l_paren and token_index > 0 and std.mem.eql(u8, tokenText(source, tokens[token_index - 1]), "call")) {
            call_opening = token_index;
        }
    }
    try std.testing.expect(declaration_index != null);
    try std.testing.expect(call_opening != null);
    const call_closing = index.matchingToken(call_opening.?);
    try std.testing.expect(call_closing != null);
    try std.testing.expectEqual(std.zig.Token.Tag.r_paren, tokens[call_closing.?].tag);
    const statement_end = index.statementEnd(declaration_index.?);
    try std.testing.expect(statement_end != null);
    try std.testing.expectEqual(std.zig.Token.Tag.semicolon, tokens[statement_end.?].tag);
    const scope_end = index.enclosingScopeEnd(declaration_index.?);
    try std.testing.expect(scope_end != null);
    try std.testing.expectEqual(std.zig.Token.Tag.r_brace, tokens[scope_end.?].tag);
}

test "usingnamespace uncertainty is limited to its container" {
    const source: [:0]const u8 =
        "const WithMixin = struct { usingnamespace Mixin; fn run() void { borrowed(); } };\n" ++
        "fn plain() void { missing(); }\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    var borrowed: ?usize = null;
    var missing: ?usize = null;
    for (tokens, 0..) |token, index| {
        if (std.mem.eql(u8, tokenText(source, token), "borrowed")) borrowed = index;
        if (std.mem.eql(u8, tokenText(source, token), "missing")) missing = index;
    }
    try std.testing.expect(usingnamespaceMayProvideName(source, tokens, borrowed.?));
    try std.testing.expect(!usingnamespaceMayProvideName(source, tokens, missing.?));
}

test "enum and struct fields are recognized as container declarations" {
    const source: [:0]const u8 =
        "const State = enum { const Code = u8; ready, waiting = 2 };\n" ++
        "const Entry = struct { value: u8 };\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    var declaration_count: usize = 0;
    for (tokens, 0..) |token, index| {
        if (token.tag == .identifier and isContainerFieldDeclaration(tokens, index)) declaration_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), declaration_count);
}

test "parameters remain visible after an error set return type" {
    const source: [:0]const u8 = "fn run(io: Io, delay: u64) error{Canceled}!void { try io.sleep(delay); }\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    var io_use: ?usize = null;
    var delay_use: ?usize = null;
    for (tokens, 0..) |token, index| {
        if (token.loc.start < std.mem.indexOf(u8, source, "try io").?) continue;
        if (std.mem.eql(u8, tokenText(source, token), "io")) io_use = index;
        if (std.mem.eql(u8, tokenText(source, token), "delay")) delay_use = index;
    }
    try std.testing.expect(findBinding(source, tokens, io_use.?) != null);
    try std.testing.expect(findBinding(source, tokens, delay_use.?) != null);
}

test "comptime parameters are visible in later parameter and return types" {
    const source: [:0]const u8 = "fn identity(comptime T: type, value: T) T { return value; }\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    var resolved_type_uses: usize = 0;
    for (tokens, 0..) |token, index| {
        if (!std.mem.eql(u8, tokenText(source, token), "T") or
            token.loc.start <= std.mem.indexOf(u8, source, "T: type").?) continue;
        if (findBinding(source, tokens, index) != null) resolved_type_uses += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), resolved_type_uses);
}

test "parameters remain visible after a labeled return type" {
    const source: [:0]const u8 =
        "fn call(self: u8, function: u8) result: { break :result u8; } { return self + function; }\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const body_start = std.mem.lastIndexOf(u8, source, "{ return").?;
    var resolved_uses: usize = 0;
    for (tokens, 0..) |token, index| {
        if (token.loc.start < body_start or token.tag != .identifier) continue;
        if (findBinding(source, tokens, index) != null) resolved_uses += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), resolved_uses);
}

test "parameters remain visible after earlier anonymous struct parameters" {
    const source: [:0]const u8 =
        "fn run(first: struct { value: u8 }, options: struct { ready: bool }) void { _ = first; _ = options; }\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const body_start = std.mem.indexOf(u8, source, "_ = first").?;
    var resolved_uses: usize = 0;
    for (tokens, 0..) |token, index| {
        if (token.loc.start < body_start or token.tag != .identifier) continue;
        if (findBinding(source, tokens, index) != null) resolved_uses += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), resolved_uses);
}

test "typed destructuring declarations introduce each binding" {
    const source: [:0]const u8 =
        "fn run(pair: struct { u8, u8 }) void { const first: u8, const second: u8 = pair; _ = first; _ = second; }\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const uses_start = std.mem.indexOf(u8, source, "_ = first").?;
    var resolved_uses: usize = 0;
    for (tokens, 0..) |token, index| {
        if (token.loc.start < uses_start or token.tag != .identifier) continue;
        if (findBinding(source, tokens, index) != null) resolved_uses += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), resolved_uses);
}

test "container declarations remain visible after fields" {
    const source: [:0]const u8 =
        "const Container = struct { value: State, const State = enum { ready }; };\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    var state_use: ?usize = null;
    for (tokens, 0..) |token, index| {
        if (token.loc.start < std.mem.indexOf(u8, source, "value: State").? or
            token.loc.start >= std.mem.indexOf(u8, source, "const State").?) continue;
        if (std.mem.eql(u8, tokenText(source, token), "State")) state_use = index;
    }
    try std.testing.expect(findBinding(source, tokens, state_use.?) != null);
}

test "aligned and ABI-named container declarations resolve before their declaration" {
    const source: [:0]const u8 =
        "const first = aligned_table[0]; const second = &external_value;\n" ++
        "const aligned_table align(64) = [_]u8{1}; extern \"c\" var external_value: u8;\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const declarations_start = std.mem.indexOf(u8, source, "const aligned_table").?;
    var resolved_uses: usize = 0;
    for (tokens, 0..) |token, index| {
        if (token.loc.start >= declarations_start or token.tag != .identifier) continue;
        const name = tokenText(source, token);
        if (!std.mem.eql(u8, name, "aligned_table") and !std.mem.eql(u8, name, "external_value")) continue;
        if (findBinding(source, tokens, index) != null) resolved_uses += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), resolved_uses);
}

test "captures span an unbraced loop expression with another capture" {
    const source: [:0]const u8 =
        "fn run(optional: ?u8, values: []u8) void { if (optional) |name| for (values, 0..) |value, index| { _ = name + value + index; }; }\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const use_start = std.mem.indexOf(u8, source, "_ = name").?;
    var name_use: ?usize = null;
    for (tokens, 0..) |token, index| {
        if (token.loc.start >= use_start and std.mem.eql(u8, tokenText(source, token), "name")) name_use = index;
    }
    try std.testing.expect(findBinding(source, tokens, name_use.?) != null);
}

test "captures span an unbraced destructuring assignment" {
    const source: [:0]const u8 =
        "fn run(optional: ?Pair) void { var x: u8 = 0; var y: u8 = 0; if (optional) |pair| x, y = pair.values(); _ = x + y; }\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const use_start = std.mem.indexOf(u8, source, "pair.values").?;
    var pair_use: ?usize = null;
    for (tokens, 0..) |token, index| {
        if (token.loc.start >= use_start and std.mem.eql(u8, tokenText(source, token), "pair")) pair_use = index;
    }
    try std.testing.expect(findBinding(source, tokens, pair_use.?) != null);
}
