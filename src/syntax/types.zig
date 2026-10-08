const std = @import("std");
const tokenize = @import("tokens.zig").tokenize;
const matchingToken = @import("tokens.zig").matchingToken;
const statementEnd = @import("tokens.zig").statementEnd;

pub fn inferredBindingType(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    binding_span: std.zig.Token.Loc,
) !?[]const u8 {
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

/// The construction conventions `T.init(...)` and `T.empty` produce a value
/// of type `T`, so a binding initialized that way has the dotted path before
/// the final member as its type expression.
pub fn initializerTypeExpression(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    binding_span: std.zig.Token.Loc,
) !?[]const u8 {
    const binding_index = for (tokens, 0..) |token, index| {
        if (token.tag == .identifier and std.meta.eql(token.loc, binding_span)) break index;
    } else return null;
    if (binding_index == 0 or
        (tokens[binding_index - 1].tag != .keyword_const and tokens[binding_index - 1].tag != .keyword_var)) return null;
    const declaration_end = statementEnd(tokens, binding_index - 1) orelse return null;
    const equal_index = for (tokens[binding_index + 1 .. declaration_end], binding_index + 1..) |token, index| {
        if (token.tag == .equal) break index;
    } else return null;
    var value_start = equal_index + 1;
    while (value_start < declaration_end and tokens[value_start].tag == .keyword_try) : (value_start += 1) {}
    if (value_start >= declaration_end or tokens[value_start].tag != .identifier) return null;
    var last_period: ?usize = null;
    var cursor = value_start + 1;
    while (cursor < declaration_end) {
        switch (tokens[cursor].tag) {
            .period => {
                if (cursor + 1 >= declaration_end or tokens[cursor + 1].tag != .identifier) return null;
                last_period = cursor;
                cursor += 2;
            },
            .l_paren => cursor = (matchingToken(tokens, cursor, .l_paren, .r_paren) orelse return null) + 1,
            else => return null,
        }
    }
    const period = last_period orelse return null;
    const constructor = source[tokens[period + 1].loc.start..tokens[period + 1].loc.end];
    if (!std.mem.eql(u8, constructor, "init") and !std.mem.eql(u8, constructor, "empty")) return null;
    return try allocator.dupe(u8, source[tokens[value_start].loc.start..tokens[period - 1].loc.end]);
}

pub fn memberSpan(
    source: []const u8,
    tokens: []const std.zig.Token,
    type_path: []const u8,
    member_name: []const u8,
) ?std.zig.Token.Loc {
    const root = TokenRange{ .start = 0, .end = tokens.len };
    const container = resolveContainer(source, tokens, root, root, type_path, 0) orelse return null;
    return directFieldSpan(source, tokens, container, member_name);
}

/// A half-open range of token indices.
pub const TokenRange = struct {
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
            !std.mem.eql(u8, source[tokens[function_index + 1].loc.start..tokens[function_index + 1].loc.end], function_name)) continue;
        const return_type = returnTypeAt(source, tokens, function_index + 1) orelse continue;
        return try allocator.dupe(u8, return_type);
    }
    return null;
}

/// The text between the parameter list of the function named at `name_index`
/// and its body (or `;`), error set included, or null when it has none.
pub fn returnTypeAt(source: []const u8, tokens: []const std.zig.Token, name_index: usize) ?[]const u8 {
    if (name_index + 1 >= tokens.len or tokens[name_index + 1].tag != .l_paren) return null;
    const parameters_end = matchingToken(tokens, name_index + 1, .l_paren, .r_paren) orelse return null;
    var body_start = parameters_end + 1;
    while (body_start < tokens.len and tokens[body_start].tag != .l_brace and
        tokens[body_start].tag != .semicolon) : (body_start += 1)
    {}
    if (body_start == tokens.len) return null;
    const return_type = std.mem.trim(u8, source[tokens[parameters_end].loc.end..tokens[body_start].loc.start], " \t\r\n");
    return if (return_type.len == 0) null else return_type;
}

/// `returnTypeAt` without a leading error set: the type a call produces on
/// success, which is what member lookup on its result needs.
pub fn successTypeAt(source: []const u8, tokens: []const std.zig.Token, name_index: usize) ?[]const u8 {
    const return_type = returnTypeAt(source, tokens, name_index) orelse return null;
    const error_union = std.mem.findScalarLast(u8, return_type, '!') orelse return return_type;
    return std.mem.trim(u8, return_type[error_union + 1 ..], " \t\r\n");
}

fn resolveContainer(
    source: []const u8,
    tokens: []const std.zig.Token,
    root: TokenRange,
    initial: TokenRange,
    type_path: []const u8,
    recursion_depth: usize,
) ?TokenRange {
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
    root: TokenRange,
    lexical_container: TokenRange,
    declaration: Declaration,
    recursion_depth: usize,
) ?TokenRange {
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
    if (!isDottedIdentifier(alias_path)) return null;
    return resolveContainer(source, tokens, root, lexical_container, alias_path, recursion_depth) orelse
        resolveContainer(source, tokens, root, root, alias_path, recursion_depth);
}

fn findDeclaration(
    source: []const u8,
    tokens: []const std.zig.Token,
    container: TokenRange,
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
    container: TokenRange,
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

pub fn isIdentifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

/// Whether `name` is exactly one Zig identifier token (keywords excluded).
pub fn isIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    var source_buffer: [256:0]u8 = undefined;
    if (name.len > source_buffer.len) return false;
    @memcpy(source_buffer[0..name.len], name);
    source_buffer[name.len] = 0;
    var tokenizer = std.zig.Tokenizer.init(source_buffer[0..name.len :0]);
    const identifier = tokenizer.next();
    return identifier.tag == .identifier and identifier.loc.end == name.len and tokenizer.next().tag == .eof;
}

pub fn isDottedIdentifier(source: []const u8) bool {
    if (source.len == 0 or source[0] == '.' or source[source.len - 1] == '.') return false;
    var segment_start: usize = 0;
    var index: usize = 0;
    while (index <= source.len) : (index += 1) {
        if (index != source.len and source[index] != '.') continue;
        if (!isIdentifier(source[segment_start..index])) return false;
        segment_start = index + 1;
    }
    return true;
}

/// A type expression without leading pointer or optional markers.
pub fn bareTypeExpression(type_expression: []const u8) []const u8 {
    var bare = std.mem.trim(u8, type_expression, " \t\r\n");
    while (bare.len != 0 and (bare[0] == '*' or bare[0] == '?')) {
        bare = bare[1..];
        if (std.mem.startsWith(u8, bare, "const ")) bare = bare["const ".len..];
    }
    return bare;
}

/// The dotted name a type expression spells once an error set and optional
/// markers are removed, or null when it is anything more complex.
pub fn namedTypeExpression(type_expression: []const u8) ?[]const u8 {
    var type_name = std.mem.trim(u8, type_expression, " \t\r\n");
    if (std.mem.findScalarLast(u8, type_name, '!')) |error_separator| {
        type_name = std.mem.trimStart(u8, type_name[error_separator + 1 ..], " \t\r\n");
    }
    while (type_name.len != 0 and type_name[0] == '?') type_name = type_name[1..];
    return if (isDottedIdentifier(type_name)) type_name else null;
}

/// The segments of `a.b(x).c`: call arguments are skipped, so a constructed
/// type such as `std.ArrayList(u8)` is the path `std`, `ArrayList`.
pub fn dottedPathSegments(allocator: std.mem.Allocator, type_expression: []const u8) !?[]const []const u8 {
    var segments: std.ArrayList([]const u8) = .empty;
    errdefer segments.deinit(allocator);
    var rest = std.mem.trim(u8, type_expression, " \t\r\n");
    while (true) {
        const boundary = std.mem.findAny(u8, rest, ".(") orelse rest.len;
        if (boundary == 0) return null;
        const segment = rest[0..boundary];
        if (!isDottedIdentifier(segment)) return null;
        try segments.append(allocator, segment);
        if (boundary == rest.len) return try segments.toOwnedSlice(allocator);
        if (rest[boundary] == '.') {
            rest = rest[boundary + 1 ..];
            continue;
        }
        var depth: usize = 0;
        var index = boundary;
        while (index < rest.len) : (index += 1) {
            if (rest[index] == '(') depth += 1;
            if (rest[index] == ')') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        if (index == rest.len) return null;
        if (index + 1 == rest.len) return try segments.toOwnedSlice(allocator);
        if (rest[index + 1] != '.') return null;
        rest = rest[index + 2 ..];
    }
}

/// The dotted receiver before the `.` that precedes `byte_offset`
/// (`a.b.` yields `a.b`), or null when the text there is not one.
pub fn memberReceiver(source: []const u8, byte_offset: usize) ?[]const u8 {
    if (byte_offset == 0 or byte_offset > source.len or source[byte_offset - 1] != '.') return null;
    var start = byte_offset - 1;
    while (start > 0) {
        const byte = source[start - 1];
        if (!isIdentifierByte(byte) and byte != '.') break;
        start -= 1;
    }
    const receiver = source[start .. byte_offset - 1];
    if (!isDottedIdentifier(receiver)) return null;
    return receiver;
}

/// The single identifier directly before the `.` that precedes `member_start`.
pub fn receiverIdentifierSpan(source: []const u8, member_start: usize) ?std.zig.Token.Loc {
    if (member_start < 2 or member_start > source.len or source[member_start - 1] != '.') return null;
    const end = member_start - 1;
    var start = end;
    while (start > 0 and isIdentifierByte(source[start - 1])) start -= 1;
    if (start == end or !isIdentifier(source[start..end])) return null;
    return .{ .start = start, .end = end };
}

pub const QualifiedReceiver = struct {
    expression: []const u8,
    start: usize,
};

/// The call chain before a member access such as `arena.allocator().dupe`;
/// null unless the chain contains at least one call.
pub fn qualifiedCallReceiver(source: []const u8, member_start: usize) ?QualifiedReceiver {
    if (member_start == 0 or source[member_start - 1] != '.') return null;
    var index = member_start - 1;
    var saw_call = false;
    while (index > 0) {
        if (source[index - 1] == ')') {
            saw_call = true;
            var depth: usize = 0;
            while (index > 0) : (index -= 1) {
                if (source[index - 1] == ')') depth += 1;
                if (source[index - 1] == '(') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            if (index == 0) return null;
            index -= 1;
        }
        const identifier_end = index;
        while (index > 0 and (std.ascii.isAlphanumeric(source[index - 1]) or source[index - 1] == '_')) : (index -= 1) {}
        if (index == identifier_end) return null;
        if (index == 0 or source[index - 1] != '.') break;
        index -= 1;
    }
    if (!saw_call) return null;
    if (!std.ascii.isAlphabetic(source[index]) and source[index] != '_') return null;
    return .{ .expression = source[index .. member_start - 1], .start = index };
}

/// The path of the file a top-level `const alias = @import("...");` imports.
pub fn importName(source: []const u8, tokens: []const std.zig.Token, alias: []const u8) ?[]const u8 {
    for (tokens, 0..) |token, index| {
        if (token.tag != .keyword_const or index + 7 >= tokens.len) continue;
        const alias_token = tokens[index + 1];
        const equal_token = tokens[index + 2];
        const import_token = tokens[index + 3];
        const opening_parenthesis = tokens[index + 4];
        const path_token = tokens[index + 5];
        if (alias_token.tag != .identifier or equal_token.tag != .equal or
            import_token.tag != .builtin or opening_parenthesis.tag != .l_paren or
            path_token.tag != .string_literal or tokens[index + 6].tag != .r_paren or
            tokens[index + 7].tag != .semicolon)
        {
            continue;
        }
        if (!std.mem.eql(u8, source[alias_token.loc.start..alias_token.loc.end], alias)) continue;
        if (!std.mem.eql(u8, source[import_token.loc.start..import_token.loc.end], "@import")) continue;
        const literal = source[path_token.loc.start..path_token.loc.end];
        if (literal.len < 2 or literal[0] != '"' or literal[literal.len - 1] != '"') return null;
        return literal[1 .. literal.len - 1];
    }
    return null;
}

/// The identifier written as the type of `name: Type`.
pub fn declaredTypeName(source: []const u8, tokens: []const std.zig.Token, name: []const u8) ?[]const u8 {
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier or index + 2 >= tokens.len) continue;
        if (tokens[index + 1].tag != .colon or tokens[index + 2].tag != .identifier) continue;
        if (!std.mem.eql(u8, source[token.loc.start..token.loc.end], name)) continue;
        const type_token = tokens[index + 2];
        return source[type_token.loc.start..type_token.loc.end];
    }
    return null;
}

pub const ContainerDeclaration = struct {
    name_index: usize,
    kind: enum { constant, function, field },
};

/// The declaration named `name` directly inside `container`.
pub fn containerDeclarationNamed(
    source: []const u8,
    tokens: []const std.zig.Token,
    container: TokenRange,
    name: []const u8,
) ?ContainerDeclaration {
    var brace_depth: usize = 0;
    var parenthesis_depth: usize = 0;
    for (tokens[container.start..container.end], container.start..) |token, index| {
        switch (token.tag) {
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .identifier => {
                if (brace_depth != 0 or parenthesis_depth != 0) continue;
                if (!std.mem.eql(u8, source[token.loc.start..token.loc.end], name)) continue;
                if (index > container.start) switch (tokens[index - 1].tag) {
                    .keyword_const, .keyword_var => return .{ .name_index = index, .kind = .constant },
                    .keyword_fn => return .{ .name_index = index, .kind = .function },
                    else => {},
                };
                if (index + 1 < container.end and tokens[index + 1].tag == .colon) {
                    return .{ .name_index = index, .kind = .field };
                }
            },
            else => {},
        }
    }
    return null;
}

fn containerLiteralRange(tokens: []const std.zig.Token, keyword_index: usize) ?TokenRange {
    var brace = keyword_index + 1;
    while (brace < tokens.len and tokens[brace].tag != .l_brace and tokens[brace].tag != .semicolon) : (brace += 1) {}
    if (brace == tokens.len or tokens[brace].tag != .l_brace) return null;
    const closing = matchingToken(tokens, brace, .l_brace, .r_brace) orelse return null;
    return .{ .start = brace + 1, .end = closing };
}

fn pathEndIndex(tokens: []const std.zig.Token, start: usize, limit: usize) ?usize {
    if (start >= limit or tokens[start].tag != .identifier) return null;
    var last = start;
    var cursor = start + 1;
    while (cursor < limit) {
        switch (tokens[cursor].tag) {
            .period => {
                if (cursor + 1 >= limit or tokens[cursor + 1].tag != .identifier) return null;
                last = cursor + 1;
                cursor += 2;
            },
            .l_paren => {
                const closing = matchingToken(tokens, cursor, .l_paren, .r_paren) orelse return null;
                last = closing;
                cursor = closing + 1;
            },
            .semicolon => return last,
            else => return null,
        }
    }
    return null;
}

/// Where following a declaration leads: into a container literal, along
/// another dotted path in the same file, or into an imported file.
pub const DeclarationDescent = union(enum) {
    container: TokenRange,
    alias_path: []const u8,
    imported_file: struct {
        file: []const u8,
        members: []const []const u8,
    },
};

/// What the constant declared at `name_index` is: a container, an alias of a
/// dotted path, or an `@import` (with the members selected from it).
pub fn constantTarget(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    name_index: usize,
) !?DeclarationDescent {
    var equal_index = name_index + 1;
    var depth: usize = 0;
    while (equal_index < tokens.len) : (equal_index += 1) {
        switch (tokens[equal_index].tag) {
            .l_paren, .l_bracket => depth += 1,
            .r_paren, .r_bracket => depth -|= 1,
            .equal => if (depth == 0) break,
            .semicolon => return null,
            else => {},
        }
    }
    if (equal_index + 1 >= tokens.len) return null;
    var value_index = equal_index + 1;
    while (value_index < tokens.len and
        (tokens[value_index].tag == .keyword_extern or tokens[value_index].tag == .keyword_packed)) : (value_index += 1)
    {}
    switch (tokens[value_index].tag) {
        .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => {
            const range = containerLiteralRange(tokens, value_index) orelse return null;
            return .{ .container = range };
        },
        else => {},
    }
    if (tokens[value_index].tag == .builtin and
        std.mem.eql(u8, source[tokens[value_index].loc.start..tokens[value_index].loc.end], "@import"))
    {
        if (value_index + 3 >= tokens.len or tokens[value_index + 1].tag != .l_paren or
            tokens[value_index + 2].tag != .string_literal or tokens[value_index + 3].tag != .r_paren) return null;
        const literal = source[tokens[value_index + 2].loc.start..tokens[value_index + 2].loc.end];
        if (literal.len < 2) return null;
        const cursor = value_index + 4;
        if (cursor < tokens.len and tokens[cursor].tag == .period) {
            const last = pathEndIndex(tokens, cursor + 1, tokens.len) orelse return null;
            var tail: std.ArrayList([]const u8) = .empty;
            errdefer tail.deinit(allocator);
            var member_index = cursor + 1;
            while (member_index <= last) : (member_index += 2) {
                if (tokens[member_index].tag != .identifier) return null;
                try tail.append(allocator, source[tokens[member_index].loc.start..tokens[member_index].loc.end]);
            }
            return .{ .imported_file = .{
                .file = literal[1 .. literal.len - 1],
                .members = try tail.toOwnedSlice(allocator),
            } };
        }
        return .{ .imported_file = .{ .file = literal[1 .. literal.len - 1], .members = &.{} } };
    }
    const last = pathEndIndex(tokens, value_index, tokens.len) orelse return null;
    return .{ .alias_path = source[tokens[value_index].loc.start..tokens[last].loc.end] };
}

/// What a `fn Name(...) type { return struct { ... }; }` type function returns.
pub fn typeFunctionResult(
    source: []const u8,
    tokens: []const std.zig.Token,
    name_index: usize,
) ?DeclarationDescent {
    if (name_index + 1 >= tokens.len or tokens[name_index + 1].tag != .l_paren) return null;
    const parameters_end = matchingToken(tokens, name_index + 1, .l_paren, .r_paren) orelse return null;
    var body_start = parameters_end + 1;
    while (body_start < tokens.len and tokens[body_start].tag != .l_brace and
        tokens[body_start].tag != .semicolon) : (body_start += 1)
    {}
    if (body_start == tokens.len or tokens[body_start].tag != .l_brace) return null;
    const return_type = std.mem.trim(u8, source[tokens[parameters_end].loc.end..tokens[body_start].loc.start], " \t\r\n");
    if (!std.mem.eql(u8, return_type, "type")) return null;
    const body_end = matchingToken(tokens, body_start, .l_brace, .r_brace) orelse return null;
    var index = body_start + 1;
    while (index < body_end) : (index += 1) {
        if (tokens[index].tag != .keyword_return) continue;
        var value_index = index + 1;
        while (value_index < body_end and
            (tokens[value_index].tag == .keyword_extern or tokens[value_index].tag == .keyword_packed)) : (value_index += 1)
        {}
        switch (tokens[value_index].tag) {
            .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => {
                const range = containerLiteralRange(tokens, value_index) orelse return null;
                return .{ .container = range };
            },
            else => {},
        }
    }
    index = body_start + 1;
    while (index < body_end) : (index += 1) {
        if (tokens[index].tag != .keyword_return) continue;
        if (pathEndIndex(tokens, index + 1, body_end)) |last| {
            return .{ .alias_path = source[tokens[index + 1].loc.start..tokens[last].loc.end] };
        }
    }
    return null;
}

/// A name declared directly inside a container.
pub const Member = struct {
    name: []const u8,
    kind: Kind,
    public: bool,
    span: std.zig.Token.Loc,

    pub const Kind = enum { function, method, constant, variable, field };
};

/// The declarations and fields directly inside `container`. Without
/// `include_private` only `pub` declarations (and fields) are listed.
pub fn containerMembers(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    container: TokenRange,
    include_private: bool,
) ![]Member {
    var members: std.ArrayList(Member) = .empty;
    errdefer members.deinit(allocator);
    var brace_depth: usize = 0;
    var parenthesis_depth: usize = 0;
    var public_pending = false;
    for (tokens[container.start..container.end], container.start..) |token, index| {
        switch (token.tag) {
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .keyword_pub => if (brace_depth == 0 and parenthesis_depth == 0) {
                public_pending = true;
            },
            .keyword_fn, .keyword_const, .keyword_var => {
                if (brace_depth != 0 or parenthesis_depth != 0 or
                    (!include_private and !public_pending) or index + 1 >= container.end) continue;
                const name_token = tokens[index + 1];
                if (name_token.tag != .identifier) continue;
                try members.append(allocator, .{
                    .name = source[name_token.loc.start..name_token.loc.end],
                    .kind = switch (token.tag) {
                        .keyword_fn => .function,
                        .keyword_const => .constant,
                        .keyword_var => .variable,
                        else => unreachable,
                    },
                    .public = public_pending,
                    .span = name_token.loc,
                });
                public_pending = false;
            },
            .identifier => {
                if (brace_depth != 0 or parenthesis_depth != 0) continue;
                const next_tag = if (index + 1 < container.end) tokens[index + 1].tag else null;
                const starts_tag = index == container.start or tokens[index - 1].tag == .comma;
                const is_field_or_tag = next_tag == .colon or
                    (starts_tag and (next_tag == null or next_tag == .comma or next_tag == .equal));
                if (!is_field_or_tag) continue;
                try members.append(allocator, .{ .name = source[token.loc.start..token.loc.end], .kind = .field, .public = true, .span = token.loc });
            },
            .semicolon => if (brace_depth == 0 and parenthesis_depth == 0) {
                public_pending = false;
            },
            else => {},
        }
    }
    return try members.toOwnedSlice(allocator);
}

/// The public declarations of a whole file.
pub fn publicMembers(allocator: std.mem.Allocator, source: []const u8, tokens: []const std.zig.Token) ![]Member {
    var members: std.ArrayList(Member) = .empty;
    errdefer members.deinit(allocator);
    var brace_depth: usize = 0;
    var public_pending = false;
    for (tokens, 0..) |token, index| {
        switch (token.tag) {
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            .keyword_pub => if (brace_depth == 0) {
                public_pending = true;
            },
            .keyword_fn, .keyword_const, .keyword_var => {
                if (brace_depth != 0 or !public_pending or index + 1 >= tokens.len) continue;
                const name_token = tokens[index + 1];
                if (name_token.tag != .identifier) continue;
                try members.append(allocator, .{
                    .name = source[name_token.loc.start..name_token.loc.end],
                    .kind = switch (token.tag) {
                        .keyword_fn => .function,
                        .keyword_const => .constant,
                        .keyword_var => .variable,
                        else => unreachable,
                    },
                    .public = true,
                    .span = name_token.loc,
                });
                public_pending = false;
            },
            .semicolon => if (brace_depth == 0) {
                public_pending = false;
            },
            else => {},
        }
    }
    return try members.toOwnedSlice(allocator);
}

/// The members of the top-level `const type_name = struct { ... }`.
pub fn structMembers(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    type_name: []const u8,
) ![]Member {
    const opening_index = for (tokens, 0..) |token, index| {
        if (token.tag != .keyword_const or index + 4 >= tokens.len) continue;
        if (tokens[index + 1].tag != .identifier or tokens[index + 2].tag != .equal or
            tokens[index + 3].tag != .keyword_struct or tokens[index + 4].tag != .l_brace)
        {
            continue;
        }
        const name_token = tokens[index + 1];
        if (std.mem.eql(u8, source[name_token.loc.start..name_token.loc.end], type_name)) break index + 4;
    } else return &.{};

    var members: std.ArrayList(Member) = .empty;
    errdefer members.deinit(allocator);
    var brace_depth: usize = 0;
    var parenthesis_depth: usize = 0;
    for (tokens[opening_index..], opening_index..) |token, index| {
        switch (token.tag) {
            .l_brace => brace_depth += 1,
            .r_brace => {
                brace_depth -= 1;
                if (brace_depth == 0) break;
            },
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .keyword_fn => {
                if (brace_depth != 1 or parenthesis_depth != 0 or index + 1 >= tokens.len) continue;
                const name_token = tokens[index + 1];
                if (name_token.tag != .identifier) continue;
                try members.append(allocator, .{
                    .name = source[name_token.loc.start..name_token.loc.end],
                    .kind = .method,
                    .public = false,
                    .span = name_token.loc,
                });
            },
            .keyword_const, .keyword_var => {
                if (brace_depth != 1 or parenthesis_depth != 0 or index + 2 >= tokens.len) continue;
                const name_token = tokens[index + 1];
                if (name_token.tag != .identifier) continue;
                if (tokens[index + 2].tag != .equal and tokens[index + 2].tag != .colon) continue;
                try members.append(allocator, .{
                    .name = source[name_token.loc.start..name_token.loc.end],
                    .kind = if (token.tag == .keyword_const) .constant else .variable,
                    .public = false,
                    .span = name_token.loc,
                });
            },
            .identifier => {
                if (brace_depth != 1 or parenthesis_depth != 0 or index + 1 >= tokens.len) continue;
                if (tokens[index + 1].tag != .colon) continue;
                try members.append(allocator, .{
                    .name = source[token.loc.start..token.loc.end],
                    .kind = .field,
                    .public = true,
                    .span = token.loc,
                });
            },
            else => {},
        }
    }
    return try members.toOwnedSlice(allocator);
}

/// Type names in `source` worth asking the compiler about: those written in a
/// type position (`x: Name`, `Name{`, `@hasField(Name`), each listed once.
pub fn shapeCandidates(allocator: std.mem.Allocator, source: []const u8, tokens: []const std.zig.Token) ![]const []const u8 {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(allocator);
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier) continue;
        var follows_colon = index > 0 and tokens[index - 1].tag == .colon;
        if (!follows_colon and index > 1 and tokens[index - 1].tag == .period) {
            var type_start = index - 1;
            while (type_start > 1 and tokens[type_start - 1].tag == .identifier and
                tokens[type_start - 2].tag == .period)
            {
                type_start -= 2;
            }
            follows_colon = type_start > 1 and tokens[type_start - 1].tag == .identifier and
                tokens[type_start - 2].tag == .colon;
        }
        const opens_initializer = index + 1 < tokens.len and tokens[index + 1].tag == .l_brace;
        const reflected_type = index >= 2 and tokens[index - 1].tag == .l_paren and
            tokens[index - 2].tag == .builtin and
            (std.mem.eql(u8, source[tokens[index - 2].loc.start..tokens[index - 2].loc.end], "@hasField") or
                std.mem.eql(u8, source[tokens[index - 2].loc.start..tokens[index - 2].loc.end], "@hasDecl"));
        if (!follows_colon and !opens_initializer and !reflected_type) continue;
        const name = source[token.loc.start..token.loc.end];
        if ((try seen.getOrPut(allocator, name)).found_existing) continue;
        try names.append(allocator, name);
    }
    return try names.toOwnedSlice(allocator);
}

test "inferred locals use the called function return type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source =
        "fn make() types.Headers.View { return undefined; }\n" ++
        "fn inspect() void { const value = make(); _ = value.slice; }";
    const binding_start = std.mem.find(u8, source, "value =") orelse unreachable;
    const tokens = try tokenize(arena.allocator(), source);
    const type_name = (try inferredBindingType(
        arena.allocator(),
        source,
        tokens,
        .{ .start = binding_start, .end = binding_start + "value".len },
    )).?;
    try std.testing.expectEqualStrings("types.Headers.View", type_name);
}

test "initializer conventions name the constructed type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source =
        "fn build(parent: std.mem.Allocator) void {\n" ++
        "    var values = std.ArrayList(u8).empty;\n" ++
        "    var arena_state = std.heap.ArenaAllocator.init(parent);\n" ++
        "    const bytes = try parent.alloc(u8, 1);\n" ++
        "    _ = .{ &values, &arena_state, bytes };\n" ++
        "}";
    const tokens = try tokenize(arena.allocator(), source);
    const values_start = std.mem.find(u8, source, "values =") orelse unreachable;
    try std.testing.expectEqualStrings("std.ArrayList(u8)", (try initializerTypeExpression(
        arena.allocator(),
        source,
        tokens,
        .{ .start = values_start, .end = values_start + "values".len },
    )).?);
    const arena_start = std.mem.find(u8, source, "arena_state =") orelse unreachable;
    try std.testing.expectEqualStrings("std.heap.ArenaAllocator", (try initializerTypeExpression(
        arena.allocator(),
        source,
        tokens,
        .{ .start = arena_start, .end = arena_start + "arena_state".len },
    )).?);
    const bytes_start = std.mem.find(u8, source, "bytes =") orelse unreachable;
    try std.testing.expectEqual(null, try initializerTypeExpression(
        arena.allocator(),
        source,
        tokens,
        .{ .start = bytes_start, .end = bytes_start + "bytes".len },
    ));
}

test "member lookup follows nested and private aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source =
        "pub const Headers = struct { pub const View = ViewStorage; };\n" ++
        "const ViewStorage = struct { slice: []const u8, count: usize };";
    const tokens = try tokenize(arena.allocator(), source);
    const span = memberSpan(source, tokens, "Headers.View", "slice").?;
    try std.testing.expectEqualStrings("slice", source[span.start..span.end]);
}

test "member resolution finds explicit struct fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source: [:0]const u8 =
        "const Profile = struct { display_name: []const u8, login_count: u32 };\n" ++
        "fn show(profile: Profile) []const u8 { return profile.display_name; }\n";
    const tokens = try tokenize(arena, source);
    const receiver_offset = std.mem.find(u8, source, "profile.").? + "profile.".len;
    try std.testing.expectEqualStrings("profile", memberReceiver(source, receiver_offset).?);
    const type_name = declaredTypeName(source, tokens, "profile").?;
    try std.testing.expectEqualStrings("Profile", type_name);
    const members = try structMembers(arena, source, tokens, type_name);
    try std.testing.expectEqual(@as(usize, 2), members.len);
    try std.testing.expectEqualStrings("display_name", members[0].name);
    try std.testing.expectEqualStrings("login_count", members[1].name);
}

test "module resolution returns only public declarations" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source: [:0]const u8 =
        "pub const default_limit: u32 = 42;\n" ++
        "const private_limit: u32 = 7;\n" ++
        "pub fn clampToLimit(value: u32) u32 { return value; }\n";
    const members = try publicMembers(arena, source, try tokenize(arena, source));
    try std.testing.expectEqual(@as(usize, 2), members.len);
    try std.testing.expectEqualStrings("default_limit", members[0].name);
    try std.testing.expectEqualStrings("clampToLimit", members[1].name);
}

test "import resolution identifies aliases" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "const catalog = @import(\"catalog.zig\");\n";
    const tokens = try tokenize(arena_state.allocator(), source);
    try std.testing.expectEqualStrings("std", importName(source, tokens, "std").?);
    try std.testing.expectEqualStrings("catalog.zig", importName(source, tokens, "catalog").?);
}

test "qualified type expressions spell their path and strip error sets" {
    try std.testing.expect(isDottedIdentifier("std.mem.Allocator"));
    try std.testing.expect(!isDottedIdentifier("std..mem"));
    try std.testing.expectEqualStrings("types.Headers", namedTypeExpression("anyerror!?types.Headers").?);
    const source = "fn load() anyerror!types.Headers { return undefined; }";
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const tokens = try tokenize(arena_state.allocator(), source);
    try std.testing.expectEqualStrings("types.Headers", successTypeAt(source, tokens, 1).?);
    try std.testing.expectEqualStrings("anyerror!types.Headers", returnTypeAt(source, tokens, 1).?);
    const segments = (try dottedPathSegments(arena_state.allocator(), "std.ArrayList(u8).Managed")).?;
    try std.testing.expectEqual(@as(usize, 3), segments.len);
}

test "names are identifiers only when Zig could declare them" {
    try std.testing.expect(isIdentifier("generated_value"));
    try std.testing.expect(!isIdentifier("generated-value"));
    try std.testing.expect(!isIdentifier(""));
}
