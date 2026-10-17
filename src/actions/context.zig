const std = @import("std");
const analysis = @import("../analysis.zig");
const tokens_util = @import("../syntax/tokens.zig");
const tokenize = tokens_util.tokenize;

pub const Candidate = struct {
    title: []const u8,
    kind: analysis.ActionKind,
    edits: []const analysis.Edit,
    preferred: bool = false,
};

pub const CandidateOptions = struct {
    preferred: bool = false,
};

pub const ActionRun = struct {
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    selection: std.zig.Token.Loc,
    shapes: []const analysis.ResolvedShape,
    candidates: *std.ArrayList(Candidate),

    pub fn add(
        context: ActionRun,
        title: []const u8,
        kind: analysis.ActionKind,
        edits: []const analysis.Edit,
        options: CandidateOptions,
    ) !void {
        try context.candidates.append(context.allocator, .{
            .title = title,
            .kind = kind,
            .edits = edits,
            .preferred = options.preferred,
        });
    }

    pub fn oneEdit(
        context: ActionRun,
        title: []const u8,
        kind: analysis.ActionKind,
        span: std.zig.Token.Loc,
        replacement: []const u8,
        options: CandidateOptions,
    ) !void {
        const edits = try context.allocator.alloc(analysis.Edit, 1);
        edits[0] = .{ .span = span, .replacement = replacement };
        try context.add(title, kind, edits, options);
    }

    pub fn tokenText(context: ActionRun, index: usize) []const u8 {
        const token = context.tokens[index];
        return context.source[token.loc.start..token.loc.end];
    }

    pub fn tokenIs(context: ActionRun, index: usize, expected: []const u8) bool {
        return index < context.tokens.len and std.mem.eql(u8, context.tokenText(index), expected);
    }

    pub fn selected(context: ActionRun, span: std.zig.Token.Loc) bool {
        return spansOverlap(context.selection, span);
    }

    pub fn matchingToken(
        context: ActionRun,
        opening: usize,
        opening_tag: std.zig.Token.Tag,
        closing_tag: std.zig.Token.Tag,
    ) ?usize {
        return tokens_util.matchingToken(context.tokens, opening, opening_tag, closing_tag);
    }

    pub fn statementEnd(context: ActionRun, start: usize) ?usize {
        return tokens_util.statementEnd(context.tokens, start);
    }

    pub fn shapeNamed(context: ActionRun, name: []const u8) ?analysis.ResolvedShape {
        for (context.shapes) |shape| if (std.mem.eql(u8, shape.type_name, name)) return shape;
        return null;
    }

    pub fn lineIndentation(context: ActionRun, offset: usize) []const u8 {
        const line_start = if (std.mem.findScalarLast(u8, context.source[0..offset], '\n')) |nl| nl + 1 else 0;
        var indentation_end = line_start;
        while (indentation_end < context.source.len and
            (context.source[indentation_end] == ' ' or context.source[indentation_end] == '\t')) : (indentation_end += 1)
        {}
        return context.source[line_start..indentation_end];
    }
};

pub fn spansOverlap(left: std.zig.Token.Loc, right: std.zig.Token.Loc) bool {
    if (left.start == left.end) return right.start <= left.start and left.start <= right.end;
    return left.start < right.end and right.start < left.end;
}

/// The contents of a plain string literal, or null when it has escapes.
pub fn stringValue(literal: []const u8) ?[]const u8 {
    if (literal.len < 2 or literal[0] != '"' or literal[literal.len - 1] != '"') return null;
    const value = literal[1 .. literal.len - 1];
    if (std.mem.findScalar(u8, value, '\\') != null) return null;
    return value;
}

pub fn selectedTokenIndex(context: ActionRun) ?usize {
    for (context.tokens, 0..) |token, index| {
        if (context.selected(token.loc)) return index;
    }
    return null;
}

pub fn containingFunction(context: ActionRun, token_index: usize) ?Function {
    var selected: ?Function = null;
    for (context.tokens[0..token_index], 0..) |token, fn_index| {
        if (token.tag != .keyword_fn) continue;
        var opening = fn_index + 1;
        while (opening < token_index and context.tokens[opening].tag != .l_paren) : (opening += 1) {}
        if (opening >= token_index) continue;
        const parameters_end = context.matchingToken(opening, .l_paren, .r_paren) orelse continue;
        var body_start = parameters_end + 1;
        while (body_start < token_index and context.tokens[body_start].tag != .l_brace) : (body_start += 1) {}
        if (body_start >= token_index) continue;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
        if (body_end <= token_index) continue;
        selected = .{
            .fn_index = fn_index,
            .parameters_end = parameters_end,
            .body_start = body_start,
            .body_end = body_end,
        };
    }
    return selected;
}

/// The innermost `struct` declaration whose braces hold the token at `index`.
pub fn enclosingStruct(tree: *const std.zig.Ast, index: usize) ?std.zig.Ast.Node.Index {
    var innermost: ?std.zig.Ast.Node.Index = null;
    var innermost_start: usize = 0;
    for (1..tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        var buffer: [2]std.zig.Ast.Node.Index = undefined;
        const container = tree.fullContainerDecl(&buffer, node) orelse continue;
        if (tree.tokenTag(container.ast.main_token) != .keyword_struct) continue;
        const start = container.ast.main_token;
        if (index <= start or index >= tree.lastToken(node) or (innermost != null and start < innermost_start)) continue;
        innermost = node;
        innermost_start = start;
    }
    return innermost;
}

/// The token of the name `const Name = struct {...}` binds to `container`, if any.
pub fn structName(context: ActionRun, tree: *const std.zig.Ast, container: std.zig.Ast.Node.Index) ?usize {
    var keyword: usize = tree.nodeMainToken(container);
    if (keyword > 0 and (context.tokens[keyword - 1].tag == .keyword_extern or context.tokens[keyword - 1].tag == .keyword_packed)) keyword -= 1;
    if (keyword < 3 or context.tokens[keyword - 1].tag != .equal or context.tokens[keyword - 2].tag != .identifier or
        (context.tokens[keyword - 3].tag != .keyword_const and context.tokens[keyword - 3].tag != .keyword_var)) return null;
    return keyword - 2;
}

/// Whether `name` denotes `container`: the name it is bound to, or a member
/// `const Self = @This();` inside it.
pub fn namesStruct(context: ActionRun, tree: *const std.zig.Ast, container: std.zig.Ast.Node.Index, name: []const u8) bool {
    if (structName(context, tree, container)) |name_index| {
        if (context.tokenIs(name_index, name)) return true;
    }
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    for (tree.fullContainerDecl(&buffer, container).?.ast.members) |member| {
        const variable = tree.fullVarDecl(member) orelse continue;
        const initializer = variable.ast.init_node.unwrap() orelse continue;
        if (context.tokenIs(variable.ast.mut_token + 1, name) and
            (tree.nodeTag(initializer) == .builtin_call_two or tree.nodeTag(initializer) == .builtin_call_two_comma) and
            std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(initializer)), "@This")) return true;
    }
    return false;
}

pub const Function = struct {
    fn_index: usize,
    parameters_end: usize,
    body_start: usize,
    body_end: usize,

    pub fn returnsError(function: Function, context: ActionRun) bool {
        for (context.tokens[function.parameters_end + 1 .. function.body_start]) |token| {
            if (token.tag == .bang) return true;
        }
        return false;
    }

    pub fn returnsVoid(function: Function, context: ActionRun) bool {
        for (context.tokens[function.parameters_end + 1 .. function.body_start], function.parameters_end + 1..) |token, index| {
            if (token.tag == .identifier and context.tokenIs(index, "void")) return true;
        }
        return function.body_start == function.parameters_end + 1;
    }
};

test "action context locates the containing function" {
    const source: [:0]const u8 = "fn run(value: u8) !void { _ = value; }";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    var candidates: std.ArrayList(Candidate) = .empty;
    const context: ActionRun = .{
        .allocator = std.testing.allocator,
        .source = source,
        .tokens = tokens,
        .selection = tokens[10].loc,
        .shapes = &.{},
        .candidates = &candidates,
    };
    const function = containingFunction(context, 10).?;
    try std.testing.expect(function.returnsError(context));
}
