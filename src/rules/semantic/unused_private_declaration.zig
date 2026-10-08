//! Private declarations that nothing in the file refers to.
const std = @import("std");

const tokenText = @import("../../syntax/tokens.zig").tokenText;
const tokenIs = @import("../../syntax/tokens.zig").tokenIs;
const matchingToken = @import("../../syntax/tokens.zig").matchingToken;
const statementEnd = @import("../../syntax/tokens.zig").statementEnd;
const lineStart = @import("../../syntax/tokens.zig").lineStart;
const removedLinesSpan = @import("../../syntax/tokens.zig").removedLinesSpan;
const attachedCommentStart = @import("../../syntax/tokens.zig").attachedCommentStart;
const insideFunctionOrTestBody = @import("../../syntax/tokens.zig").insideFunctionOrTestBody;
const rule_context = @import("../context.zig");
const RuleRun = rule_context.RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

const Fix = types.Fix;

pub const rules = [_]types.Rule{
    .unused_private_declaration,
};

pub fn run(context: RuleRun) !void {
    try findUnusedPrivateDeclarations(context);
}

const PrivateDeclaration = struct {
    name_index: usize,
    kind: enum { constant, function },
};

fn findUnusedPrivateDeclarations(context: RuleRun) !void {
    const source = context.source;
    const tokens = context.tokens;
    const level = context.level(.unused_private_declaration);
    if (level == .off) return;
    var declarations: std.ArrayList(PrivateDeclaration) = .empty;
    defer declarations.deinit(context.allocator);
    for (0..context.tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        if (context.tree.fullVarDecl(node)) |declaration| {
            const keyword_index: usize = declaration.ast.mut_token;
            if (keyword_index >= tokens.len or tokens[keyword_index].tag != .keyword_const or
                keyword_index + 1 >= tokens.len or tokens[keyword_index + 1].tag != .identifier or
                !declarationIsPrivate(tokens, keyword_index) or insideFunctionOrTestBody(tokens, keyword_index)) continue;
            const statement_end = statementEnd(tokens, keyword_index) orelse continue;
            var equal_index = keyword_index + 2;
            while (equal_index < statement_end and tokens[equal_index].tag != .equal) : (equal_index += 1) {}
            const direct_import = equal_index + 5 == statement_end and tokens[equal_index + 1].tag == .builtin and
                tokenIs(source, tokens[equal_index + 1], "@import") and tokens[equal_index + 2].tag == .l_paren and
                tokens[equal_index + 3].tag == .string_literal and tokens[equal_index + 4].tag == .r_paren;
            if (!direct_import) try declarations.append(context.allocator, .{ .name_index = keyword_index + 1, .kind = .constant });
            continue;
        }
        if (context.tree.nodeTag(node) != .fn_decl) continue;
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const function = context.tree.fullFnProto(&buffer, node) orelse continue;
        const keyword_index: usize = function.ast.fn_token;
        if (keyword_index + 1 >= tokens.len or tokens[keyword_index + 1].tag != .identifier or
            !declarationIsPrivate(tokens, keyword_index)) continue;
        try declarations.append(context.allocator, .{ .name_index = keyword_index + 1, .kind = .function });
    }
    if (declarations.items.len == 0) return;
    var occurrence_counts: std.StringHashMapUnmanaged(usize) = .empty;
    defer occurrence_counts.deinit(context.allocator);
    for (tokens) |token| {
        const entry = try occurrence_counts.getOrPutValue(context.allocator, tokenText(source, token), 0);
        entry.value_ptr.* += 1;
    }
    var reflected_names = try collectReflectedNames(context.allocator, source, tokens);
    defer reflected_names.names.deinit(context.allocator);
    if (reflected_names.wildcard) return;
    for (declarations.items) |declaration| {
        const name_token = tokens[declaration.name_index];
        const name = tokenText(source, name_token);
        if (std.mem.eql(u8, name, "_") or std.mem.startsWith(u8, name, "@\"") or
            isImplicitDeclarationName(name) or (occurrence_counts.get(name) orelse 0) != 1 or
            reflected_names.names.contains(name)) continue;
        const fixes = try unusedDeclarationFixes(context.allocator, source, tokens, declaration);
        const message = try context.allocator.print(
            "private {s} '{s}' is never referenced",
            .{ @tagName(declaration.kind), name },
        );
        errdefer context.allocator.free(message);
        try context.emit(.{
            .rule = .unused_private_declaration,
            .level = level,
            .span = name_token.loc,
            .message = message,
            .fixes = fixes,
        });
    }
}

fn unusedDeclarationFixes(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    declaration: PrivateDeclaration,
) ![]const Fix {
    const keyword_index = declaration.name_index - 1;
    var declaration_start = keyword_index;
    while (declaration_start > 0) {
        switch (tokens[declaration_start - 1].tag) {
            .keyword_inline, .keyword_noinline, .keyword_comptime, .keyword_threadlocal => declaration_start -= 1,
            else => break,
        }
    }
    const last_index: ?usize = switch (declaration.kind) {
        .constant => statementEnd(tokens, keyword_index),
        .function => end: {
            if (declaration.name_index + 1 >= tokens.len or tokens[declaration.name_index + 1].tag != .l_paren) break :end null;
            const parameters_end = matchingToken(tokens, declaration.name_index + 1, .l_paren, .r_paren) orelse break :end null;
            var body_open = parameters_end + 1;
            while (body_open < tokens.len and tokens[body_open].tag != .l_brace and tokens[body_open].tag != .semicolon) : (body_open += 1) {}
            if (body_open >= tokens.len or tokens[body_open].tag != .l_brace) break :end null;
            break :end matchingToken(tokens, body_open, .l_brace, .r_brace);
        },
    };
    const end_index = last_index orelse return &.{};
    const line_start = lineStart(source, tokens[declaration_start].loc.start);
    if (attachedCommentStart(source, line_start) != line_start) return &.{};
    const declaration_span = removedLinesSpan(source, tokens[declaration_start].loc.start, tokens[end_index].loc.end);
    const fixes = try Fix.single(allocator, .{
        .title = "Remove unused declaration",
        .span = declaration_span,
        .replacement = "",
    });
    return fixes;
}

fn declarationIsPrivate(tokens: []const std.zig.Token, keyword_index: usize) bool {
    var cursor = keyword_index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .keyword_pub, .keyword_export, .keyword_extern => return false,
            .keyword_inline,
            .keyword_noinline,
            .keyword_comptime,
            .keyword_threadlocal,
            .doc_comment,
            .container_doc_comment,
            => {},
            else => return true,
        }
    }
    return true;
}

fn isImplicitDeclarationName(name: []const u8) bool {
    return std.mem.eql(u8, name, "main") or std.mem.eql(u8, name, "panic") or
        std.mem.eql(u8, name, "test_runner");
}

const ReflectedNames = struct {
    /// A reflection call whose name argument is not a plain string literal may
    /// reference any declaration.
    wildcard: bool,
    names: std.StringHashMapUnmanaged(void),
};

fn collectReflectedNames(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
) !ReflectedNames {
    var collected: ReflectedNames = .{ .wildcard = false, .names = .empty };
    for (tokens, 0..) |token, index| {
        if (token.tag != .builtin or
            (!tokenIs(source, token, "@field") and !tokenIs(source, token, "@hasDecl") and
                !tokenIs(source, token, "@hasField"))) continue;
        if (index + 1 >= tokens.len or tokens[index + 1].tag != .l_paren) {
            collected.wildcard = true;
            return collected;
        }
        const closing = matchingToken(tokens, index + 1, .l_paren, .r_paren) orelse {
            collected.wildcard = true;
            return collected;
        };
        var comma: ?usize = null;
        var depth: usize = 0;
        for (tokens[index + 2 .. closing], index + 2..) |argument_token, argument_index| {
            switch (argument_token.tag) {
                .l_paren, .l_brace, .l_bracket => depth += 1,
                .r_paren, .r_brace, .r_bracket => depth -|= 1,
                .comma => if (depth == 0) {
                    comma = argument_index;
                    break;
                },
                else => {},
            }
        }
        const name_index = (comma orelse {
            collected.wildcard = true;
            return collected;
        }) + 1;
        if (name_index >= closing or tokens[name_index].tag != .string_literal) {
            collected.wildcard = true;
            return collected;
        }
        const literal = tokenText(source, tokens[name_index]);
        if (literal.len >= 2) try collected.names.put(allocator, literal[1 .. literal.len - 1], {});
    }
    return collected;
}

test "unused private declarations omit public used and reflected names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const used = 1;\n" ++
        "const unused = 2;\n" ++
        "const reflected = 3;\n" ++
        "pub const public_unused = 4;\n" ++
        "fn private_unused() void {}\n" ++
        "pub fn run() void { _ = used; _ = @field(@This(), \"reflected\"); }\n";
    const configuration = support.only(&.{.unused_private_declaration}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var names: std.ArrayList([]const u8) = .empty;
    for (found) |finding| if (finding.rule == .unused_private_declaration) {
        try names.append(arena.allocator(), source[finding.span.start..finding.span.end]);
    };
    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualStrings("unused", names.items[0]);
    try std.testing.expectEqualStrings("private_unused", names.items[1]);
}

test "unused private declarations offer whole declaration removal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const unused = 2;\n" ++
        "// The comment blocks deletion.\n" ++
        "const commented = 3;\n" ++
        "fn orphan() void {}\n" ++
        "pub fn run() void {}\n";
    const configuration = support.only(&.{.unused_private_declaration}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var declaration_count: usize = 0;
    for (found) |finding| if (finding.rule == .unused_private_declaration) {
        declaration_count += 1;
        const name = source[finding.span.start..finding.span.end];
        if (std.mem.eql(u8, name, "unused")) {
            try std.testing.expectEqual(@as(usize, 1), finding.fixes.len);
            const span = finding.fixes[0].edits[0].span;
            try std.testing.expectEqualStrings("const unused = 2;\n", source[span.start..span.end]);
        } else if (std.mem.eql(u8, name, "commented")) {
            try std.testing.expectEqual(@as(usize, 0), finding.fixes.len);
        } else if (std.mem.eql(u8, name, "orphan")) {
            try std.testing.expectEqual(@as(usize, 1), finding.fixes.len);
            const span = finding.fixes[0].edits[0].span;
            try std.testing.expectEqualStrings("fn orphan() void {}\n", source[span.start..span.end]);
        } else return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(@as(usize, 3), declaration_count);
}
