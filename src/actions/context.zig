const std = @import("std");
const analysis = @import("../analysis.zig");

pub const Candidate = struct {
    title: []const u8,
    kind: analysis.ActionKind,
    edits: []const analysis.Edit,
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
        preferred: bool,
    ) !void {
        try context.candidates.append(context.allocator, .{
            .title = title,
            .kind = kind,
            .edits = edits,
            .preferred = preferred,
        });
    }

    pub fn oneEdit(
        context: ActionRun,
        title: []const u8,
        kind: analysis.ActionKind,
        span: std.zig.Token.Loc,
        replacement: []const u8,
        preferred: bool,
    ) !void {
        const edits = try context.allocator.alloc(analysis.Edit, 1);
        edits[0] = .{ .span = span, .replacement = replacement };
        try context.add(title, kind, edits, preferred);
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
        var depth: usize = 0;
        for (context.tokens[opening..], opening..) |token, index| {
            if (token.tag == opening_tag) depth += 1;
            if (token.tag != closing_tag) continue;
            depth -= 1;
            if (depth == 0) return index;
        }
        return null;
    }

    pub fn statementEnd(context: ActionRun, start: usize) ?usize {
        var parenthesis_depth: usize = 0;
        var bracket_depth: usize = 0;
        var brace_depth: usize = 0;
        for (context.tokens[start..], start..) |token, index| switch (token.tag) {
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .l_bracket => bracket_depth += 1,
            .r_bracket => bracket_depth -|= 1,
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            .semicolon => if (parenthesis_depth == 0 and bracket_depth == 0 and brace_depth == 0) return index,
            else => {},
        };
        return null;
    }

    pub fn shapeNamed(context: ActionRun, name: []const u8) ?analysis.ResolvedShape {
        for (context.shapes) |shape| if (std.mem.eql(u8, shape.type_name, name)) return shape;
        return null;
    }

    pub fn lineIndentation(context: ActionRun, offset: usize) []const u8 {
        const line_start = (std.mem.lastIndexOfScalar(u8, context.source[0..offset], '\n') orelse 0) +
            @intFromBool(std.mem.lastIndexOfScalar(u8, context.source[0..offset], '\n') != null);
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

pub fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return try tokens.toOwnedSlice(allocator);
        try tokens.append(allocator, token);
    }
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
