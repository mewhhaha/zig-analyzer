const std = @import("std");

pub fn inferredBindingType(
    allocator: std.mem.Allocator,
    source_bytes: []const u8,
    binding_span: std.zig.Token.Loc,
) !?[]const u8 {
    const source = try allocator.allocSentinel(u8, source_bytes.len, 0);
    defer allocator.free(source);
    @memcpy(source, source_bytes);
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);
    const binding_index = for (tokens, 0..) |token, index| {
        if (token.tag == .identifier and std.meta.eql(token.loc, binding_span)) break index;
    } else return null;
    if (binding_index == 0 or
        (tokens[binding_index - 1].tag != .keyword_const and tokens[binding_index - 1].tag != .keyword_var)) return null;
    const declaration_end = statementEnd(tokens, binding_index - 1) orelse return null;
    var colon_index: ?usize = null;
    var equal_index: ?usize = null;
    for (tokens[binding_index + 1 .. declaration_end], binding_index + 1..) |token, index| {
        if (token.tag == .colon and colon_index == null) colon_index = index;
        if (token.tag == .equal) {
            equal_index = index;
            break;
        }
    }
    if (colon_index) |colon| {
        const type_end = equal_index orelse declaration_end;
        if (type_end == colon + 1) return null;
        return try allocator.dupe(u8, std.mem.trim(
            u8,
            source[tokens[colon].loc.end..tokens[type_end - 1].loc.end],
            " \t\r\n",
        ));
    }
    var callee_index = (equal_index orelse return null) + 1;
    while (callee_index < declaration_end and tokens[callee_index].tag == .keyword_try) : (callee_index += 1) {}
    if (callee_index + 1 >= declaration_end or tokens[callee_index].tag != .identifier or
        tokens[callee_index + 1].tag != .l_paren) return null;
    const callee_name = source[tokens[callee_index].loc.start..tokens[callee_index].loc.end];
    return try functionReturnType(allocator, source, tokens, callee_name);
}

pub fn memberSpan(
    allocator: std.mem.Allocator,
    source_bytes: []const u8,
    type_path: []const u8,
    member_name: []const u8,
) !?std.zig.Token.Loc {
    const source = try allocator.allocSentinel(u8, source_bytes.len, 0);
    defer allocator.free(source);
    @memcpy(source, source_bytes);
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);
    const root = Container{ .start = 0, .end = tokens.len };
    const container = resolveContainer(source, tokens, root, root, type_path, 0) orelse return null;
    return directFieldSpan(source, tokens, container, member_name);
}

const Container = struct {
    start: usize,
    end: usize,
};

const Declaration = struct {
    rhs_start: usize,
    rhs_end: usize,
};

fn functionReturnType(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    function_name: []const u8,
) !?[]const u8 {
    for (tokens, 0..) |token, function_index| {
        if (token.tag != .keyword_fn or function_index + 2 >= tokens.len or
            tokens[function_index + 1].tag != .identifier or
            !std.mem.eql(u8, source[tokens[function_index + 1].loc.start..tokens[function_index + 1].loc.end], function_name) or
            tokens[function_index + 2].tag != .l_paren) continue;
        const parameters_end = matchingToken(tokens, function_index + 2, .l_paren, .r_paren) orelse continue;
        var body_index = parameters_end + 1;
        while (body_index < tokens.len and tokens[body_index].tag != .l_brace and
            tokens[body_index].tag != .semicolon) : (body_index += 1)
        {}
        if (body_index == tokens.len or body_index == parameters_end + 1) return null;
        const return_type = std.mem.trim(
            u8,
            source[tokens[parameters_end].loc.end..tokens[body_index].loc.start],
            " \t\r\n",
        );
        if (return_type.len == 0) return null;
        return try allocator.dupe(u8, return_type);
    }
    return null;
}

fn resolveContainer(
    source: []const u8,
    tokens: []const std.zig.Token,
    root: Container,
    initial: Container,
    type_path: []const u8,
    recursion_depth: usize,
) ?Container {
    if (recursion_depth == 16 or type_path.len == 0) return null;
    var current = initial;
    var segments = std.mem.splitScalar(u8, type_path, '.');
    while (segments.next()) |segment| {
        if (segment.len == 0) return null;
        const declaration = findDeclaration(source, tokens, current, segment) orelse
            if (!std.meta.eql(current, root)) findDeclaration(source, tokens, root, segment) orelse return null else return null;
        current = containerFromDeclaration(source, tokens, root, current, declaration, recursion_depth + 1) orelse return null;
    }
    return current;
}

fn containerFromDeclaration(
    source: []const u8,
    tokens: []const std.zig.Token,
    root: Container,
    lexical_container: Container,
    declaration: Declaration,
    recursion_depth: usize,
) ?Container {
    var saw_container_keyword = false;
    for (tokens[declaration.rhs_start..declaration.rhs_end], declaration.rhs_start..) |token, index| {
        switch (token.tag) {
            .keyword_struct, .keyword_union, .keyword_enum => saw_container_keyword = true,
            .l_brace => if (saw_container_keyword) return .{
                .start = index + 1,
                .end = matchingToken(tokens, index, .l_brace, .r_brace) orelse return null,
            },
            .identifier, .period => {},
            else => if (!saw_container_keyword) break,
        }
    }
    const alias_path = source[tokens[declaration.rhs_start].loc.start..tokens[declaration.rhs_end - 1].loc.end];
    if (!dottedIdentifier(alias_path)) return null;
    return resolveContainer(source, tokens, root, lexical_container, alias_path, recursion_depth) orelse
        resolveContainer(source, tokens, root, root, alias_path, recursion_depth);
}

fn findDeclaration(
    source: []const u8,
    tokens: []const std.zig.Token,
    container: Container,
    name: []const u8,
) ?Declaration {
    var brace_depth: usize = 0;
    for (tokens[container.start..container.end], container.start..) |token, index| {
        if (token.tag == .l_brace) {
            brace_depth += 1;
            continue;
        }
        if (token.tag == .r_brace) {
            brace_depth -|= 1;
            continue;
        }
        if (brace_depth != 0 or token.tag != .keyword_const or index + 2 >= container.end or
            tokens[index + 1].tag != .identifier or tokens[index + 2].tag != .equal or
            !std.mem.eql(u8, source[tokens[index + 1].loc.start..tokens[index + 1].loc.end], name)) continue;
        const declaration_end = statementEnd(tokens, index) orelse return null;
        if (declaration_end <= index + 3) return null;
        return .{ .rhs_start = index + 3, .rhs_end = declaration_end };
    }
    return null;
}

fn directFieldSpan(
    source: []const u8,
    tokens: []const std.zig.Token,
    container: Container,
    member_name: []const u8,
) ?std.zig.Token.Loc {
    var brace_depth: usize = 0;
    var parenthesis_depth: usize = 0;
    for (tokens[container.start..container.end], container.start..) |token, index| {
        switch (token.tag) {
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            else => {},
        }
        if (brace_depth != 0 or parenthesis_depth != 0 or token.tag != .identifier or
            index + 1 >= container.end or tokens[index + 1].tag != .colon) continue;
        if (std.mem.eql(u8, source[token.loc.start..token.loc.end], member_name)) return token.loc;
    }
    return null;
}

fn dottedIdentifier(source: []const u8) bool {
    if (source.len == 0 or source[0] == '.' or source[source.len - 1] == '.') return false;
    var segment_start: usize = 0;
    var index: usize = 0;
    while (index <= source.len) : (index += 1) {
        if (index != source.len and source[index] != '.') continue;
        if (segment_start == index) return false;
        for (source[segment_start..index], 0..) |character, character_index| {
            if (character_index == 0) {
                if (!std.ascii.isAlphabetic(character) and character != '_') return false;
            } else if (!std.ascii.isAlphanumeric(character) and character != '_') return false;
        }
        segment_start = index + 1;
    }
    return true;
}

fn statementEnd(tokens: []const std.zig.Token, start: usize) ?usize {
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

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return try tokens.toOwnedSlice(allocator);
        try tokens.append(allocator, token);
    }
}

test "inferred locals use the called function return type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source =
        "fn make() types.Headers.View { return undefined; }\n" ++
        "fn inspect() void { const value = make(); _ = value.slice; }";
    const binding_start = std.mem.indexOf(u8, source, "value =") orelse unreachable;
    const type_name = (try inferredBindingType(
        arena.allocator(),
        source,
        .{ .start = binding_start, .end = binding_start + "value".len },
    )).?;
    try std.testing.expectEqualStrings("types.Headers.View", type_name);
}

test "member lookup follows nested and private aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source =
        "pub const Headers = struct { pub const View = ViewStorage; };\n" ++
        "const ViewStorage = struct { slice: []const u8, count: usize };";
    const span = (try memberSpan(arena.allocator(), source, "Headers.View", "slice")).?;
    try std.testing.expectEqualStrings("slice", source[span.start..span.end]);
}
