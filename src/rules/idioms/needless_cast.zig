//! Casts whose operand already has the target type, casts to the type their
//! destination already declares, and nested casts that repeat it.
const std = @import("std");
const Ast = std.zig.Ast;

const containsComment = @import("../../syntax/tokens.zig").containsComment;
const tokenText = @import("../../syntax/tokens.zig").tokenText;
const tokenIs = @import("../../syntax/tokens.zig").tokenIs;
const rule_context = @import("../context.zig");
const RuleRun = rule_context.RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

const Fix = types.Fix;

pub const rules = [_]types.Rule{
    .needless_cast,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.needless_cast);
    if (level == .off) return;
    var reported: std.AutoHashMapUnmanaged(Ast.TokenIndex, void) = .empty;
    defer reported.deinit(context.allocator);
    try findTypedDestinationCasts(context, level, &reported);
    try findNeedlessCasts(context, level, &reported);
}

fn findNeedlessCasts(context: RuleRun, level: types.Level, reported: *const std.AutoHashMapUnmanaged(Ast.TokenIndex, void)) !void {
    const source = context.source;
    const tokens = context.tokens;
    for (tokens, 0..) |token, index| {
        if (token.tag != .builtin or index + 3 >= tokens.len or tokens[index + 1].tag != .l_paren) continue;
        const builtin_name = tokenText(source, token);
        if (tokenIs(source, token, "@as")) {
            if (reported.contains(@intCast(index))) continue;
            if (index + 5 >= tokens.len or tokens[index + 2].tag != .identifier or tokens[index + 3].tag != .comma) continue;
            const outer_close = context.matchingToken(index + 1, .l_paren, .r_paren) orelse continue;
            const type_name = tokenText(source, tokens[index + 2]);
            var replacement: []const u8 = undefined;
            var message: []const u8 = undefined;
            if (tokenIs(source, tokens[index + 4], "@as") and tokens[index + 5].tag == .l_paren and index + 7 < tokens.len and
                tokens[index + 6].tag == .identifier and tokens[index + 7].tag == .comma and
                std.mem.eql(u8, type_name, tokenText(source, tokens[index + 6])))
            {
                const inner_close = context.matchingToken(index + 5, .l_paren, .r_paren) orelse continue;
                if (inner_close + 1 != outer_close) continue;
                replacement = source[tokens[index + 4].loc.start..tokens[inner_close].loc.end];
                message = try context.allocator.print("nested cast to '{s}' repeats the same proven type", .{type_name});
            } else if (tokens[index + 4].tag == .identifier and index + 5 == outer_close and
                context.scopes.bindingHasType(source, tokens, index + 4, type_name))
            {
                replacement = tokenText(source, tokens[index + 4]);
                message = try context.allocator.print(
                    "cast of '{s}' to its proven type '{s}' is unnecessary",
                    .{ replacement, type_name },
                );
            } else continue;
            const fixes = try Fix.single(context.allocator, .{
                .title = "Remove redundant cast",
                .span = .{ .start = token.loc.start, .end = tokens[outer_close].loc.end },
                .replacement = replacement,
                .preferred = true,
                .fix_all = true,
            });
            try context.emit(.{
                .rule = .needless_cast,
                .level = level,
                .span = token.loc,
                .message = message,
                .fixes = fixes,
            });
        } else if (isSingleArgumentCastBuiltin(builtin_name)) {
            if (tokens[index + 2].tag != .builtin or !std.mem.eql(u8, builtin_name, tokenText(source, tokens[index + 2]))) continue;
            if (tokens[index + 3].tag != .l_paren) continue;
            const outer_close = context.matchingToken(index + 1, .l_paren, .r_paren) orelse continue;
            const inner_close = context.matchingToken(index + 3, .l_paren, .r_paren) orelse continue;
            if (inner_close + 1 != outer_close and !(inner_close + 2 == outer_close and tokens[inner_close + 1].tag == .comma)) continue;
            const replacement = source[tokens[index + 2].loc.start..tokens[inner_close].loc.end];
            const fixes = try Fix.single(context.allocator, .{
                .title = "Remove redundant cast",
                .span = .{ .start = token.loc.start, .end = tokens[outer_close].loc.end },
                .replacement = replacement,
                .preferred = true,
                .fix_all = true,
            });
            try context.emit(.{
                .rule = .needless_cast,
                .level = level,
                .span = token.loc,
                .message = try context.allocator.print("nested '{s}' is redundant", .{builtin_name}),
                .fixes = fixes,
            });
        }
    }
}

/// `const x: T = @as(T, e)` and `return @as(R, e)` in a function returning
/// `R`: the destination already gives `e` its result type. The types must be
/// spelled the same, which in one scope is the same type; `!R` and `?R`
/// destinations are left alone because they give `e` a different result type.
fn findTypedDestinationCasts(
    context: RuleRun,
    level: types.Level,
    reported: *std.AutoHashMapUnmanaged(Ast.TokenIndex, void),
) !void {
    const tree = context.tree;
    var return_types: ?std.AutoHashMapUnmanaged(Ast.TokenIndex, Ast.Node.OptionalIndex) = null;
    defer if (return_types) |*map| map.deinit(context.allocator);
    for (0..tree.nodes.len) |raw_node| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        switch (tree.nodeTag(node)) {
            .simple_var_decl, .local_var_decl, .aligned_var_decl, .global_var_decl => {
                const declaration = tree.fullVarDecl(node).?;
                const destination = declaration.ast.type_node.unwrap() orelse continue;
                const value = declaration.ast.init_node.unwrap() orelse continue;
                try reportTypedCast(context, level, reported, value, destination);
            },
            .@"return" => {
                const value = tree.nodeData(node).opt_node.unwrap() orelse continue;
                if (castOperands(tree, value) == null) continue;
                if (return_types == null) return_types = try functionReturnTypes(context);
                const destination = enclosingReturnType(context, &return_types.?, tree.nodeMainToken(node)) orelse continue;
                try reportTypedCast(context, level, reported, value, destination);
            },
            else => {},
        }
    }
}

fn reportTypedCast(
    context: RuleRun,
    level: types.Level,
    reported: *std.AutoHashMapUnmanaged(Ast.TokenIndex, void),
    cast: Ast.Node.Index,
    destination: Ast.Node.Index,
) !void {
    const tree = context.tree;
    const cast_type, var operand = castOperands(tree, cast) orelse return;
    if (!sameTokens(context, cast_type, destination)) return;
    try reported.put(context.allocator, tree.nodeMainToken(cast), {});
    // `@as(T, @as(T, e))` loses both casts at once, so the fix is idempotent.
    while (castOperands(tree, operand)) |inner| {
        if (!sameTokens(context, inner[0], destination)) break;
        try reported.put(context.allocator, tree.nodeMainToken(operand), {});
        operand = inner[1];
    }
    const cast_span = nodeSpan(context, cast);
    const operand_span = nodeSpan(context, operand);
    const fixes: []const Fix = if (containsComment(context.source[cast_span.start..operand_span.start]) or
        containsComment(context.source[operand_span.end..cast_span.end]))
        &.{}
    else
        try Fix.single(context.allocator, .{
            .title = "Remove redundant cast",
            .span = cast_span,
            .replacement = context.source[operand_span.start..operand_span.end],
            .preferred = true,
            .fix_all = true,
        });
    try context.emit(.{
        .rule = .needless_cast,
        .level = level,
        .span = context.tokens[tree.nodeMainToken(cast)].loc,
        .message = try context.allocator.print(
            "cast to '{s}' repeats the type its destination already declares",
            .{tree.getNodeSource(cast_type)},
        ),
        .fixes = fixes,
    });
}

/// The type and operand of `@as(T, e)`.
fn castOperands(tree: *const Ast, node: Ast.Node.Index) ?[2]Ast.Node.Index {
    switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma => {},
        else => return null,
    }
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@as")) return null;
    var buffer: [2]Ast.Node.Index = undefined;
    const parameters = tree.builtinCallParams(&buffer, node) orelse return null;
    if (parameters.len != 2) return null;
    return .{ parameters[0], parameters[1] };
}

/// Whether two nodes are spelled with the same tokens.
fn sameTokens(context: RuleRun, left: Ast.Node.Index, right: Ast.Node.Index) bool {
    const tree = context.tree;
    const left_first = tree.firstToken(left);
    const right_first = tree.firstToken(right);
    const count = tree.lastToken(left) - left_first;
    if (tree.lastToken(right) - right_first != count) return false;
    for (0..count + 1) |offset| {
        const left_token = context.tokens[left_first + offset];
        const right_token = context.tokens[right_first + offset];
        if (left_token.tag != right_token.tag or
            !std.mem.eql(u8, tokenText(context.source, left_token), tokenText(context.source, right_token))) return false;
    }
    return true;
}

fn nodeSpan(context: RuleRun, node: Ast.Node.Index) std.zig.Token.Loc {
    return .{
        .start = context.tokens[context.tree.firstToken(node)].loc.start,
        .end = context.tokens[context.tree.lastToken(node)].loc.end,
    };
}

/// The return type of each function by the brace opening its body; `.none`
/// when the function infers an error set, so `R` is not its return type.
fn functionReturnTypes(context: RuleRun) !std.AutoHashMapUnmanaged(Ast.TokenIndex, Ast.Node.OptionalIndex) {
    const tree = context.tree;
    var map: std.AutoHashMapUnmanaged(Ast.TokenIndex, Ast.Node.OptionalIndex) = .empty;
    errdefer map.deinit(context.allocator);
    for (0..tree.nodes.len) |raw_node| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        if (tree.nodeTag(node) != .fn_decl) continue;
        const prototype_node, const body = tree.nodeData(node).node_and_node;
        var buffer: [1]Ast.Node.Index = undefined;
        const prototype = tree.fullFnProto(&buffer, prototype_node) orelse continue;
        const return_type = prototype.ast.return_type.unwrap() orelse continue;
        const inferred_errors = tree.tokenTag(tree.firstToken(return_type) - 1) == .bang;
        try map.put(context.allocator, tree.nodeMainToken(body), if (inferred_errors) .none else return_type.toOptional());
    }
    return map;
}

/// The return type of the function whose body holds `return_token`; null in a
/// test or when the function infers its error set.
fn enclosingReturnType(
    context: RuleRun,
    return_types: *const std.AutoHashMapUnmanaged(Ast.TokenIndex, Ast.Node.OptionalIndex),
    return_token: Ast.TokenIndex,
) ?Ast.Node.Index {
    var brace = context.enclosingOpeningBrace(return_token);
    while (brace) |opening| : (brace = context.enclosingOpeningBrace(opening)) {
        if (return_types.get(@intCast(opening))) |return_type| return return_type.unwrap();
        // A test body or a container ends the search: `return` cannot leave either.
        if (opening == 0) return null;
        var before = opening - 1;
        // `union(enum) {` and `packed struct(u32) {` name their container before the parentheses.
        if (context.tokens[before].tag == .r_paren) before = (context.scopes.matchingToken(before) orelse return null) -| 1;
        switch (context.tokens[before].tag) {
            .keyword_test, .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => return null,
            else => {},
        }
        if (opening >= 2 and context.tokens[opening - 2].tag == .keyword_test) return null;
    }
    return null;
}

fn isSingleArgumentCastBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "@intCast") or
        std.mem.eql(u8, name, "@floatCast") or
        std.mem.eql(u8, name, "@ptrCast") or
        std.mem.eql(u8, name, "@alignCast") or
        std.mem.eql(u8, name, "@truncate") or
        std.mem.eql(u8, name, "@addrSpaceCast");
}

test "needless cast proof stays within the enclosing function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn widen(size: u32) u32 { return @as(u32, size); }\n" ++
        "fn narrow(size: u16) u64 { return @as(u32, size); }\n";
    const configuration = support.only(&.{.needless_cast}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var cast_count: usize = 0;
    for (found) |finding| if (finding.rule == .needless_cast) {
        cast_count += 1;
        try std.testing.expect(finding.span.start < std.mem.find(u8, source, "fn narrow").?);
    };
    try std.testing.expectEqual(@as(usize, 1), cast_count);
}

test "needless cast catches nested identical casts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn cast(x: u32) u8 {\n" ++
        "    const a = @intCast(@intCast(x));\n" ++
        "    const b = @truncate(@truncate(x));\n" ++
        "    return a + b;\n" ++
        "}\n";
    const configuration = support.only(&.{.needless_cast}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var cast_count: usize = 0;
    for (found) |finding| if (finding.rule == .needless_cast) {
        cast_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), cast_count);
}

test "casts to the type a declaration or return already declares are needless" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn declared(e: u16) u32 {\n" ++
        "    const x: u32 = @as(u32, e + 1);\n" ++
        "    var y: u8 = @as(u8, 5);\n" ++
        "    y += 1;\n" ++
        "    const z: u32 = @as(u32, @as(u32, e));\n" ++
        "    return x + y + z;\n" ++
        "}\n" ++
        "fn returned(e: u16) u32 {\n" ++
        "    if (e > 3) {\n" ++
        "        return @as(u32, e);\n" ++
        "    }\n" ++
        "    return @as(u32, @intCast(e));\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.needless_cast}, .warning));
    try std.testing.expectEqual(@as(usize, 5), found.len);
    var replacements: [5][]const u8 = undefined;
    for (found, &replacements) |finding, *replacement| replacement.* = finding.fixes[0].edits[0].replacement;
    std.mem.sort([]const u8, &replacements, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    for ([_][]const u8{ "5", "@intCast(e)", "e", "e", "e + 1" }, replacements) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "casts that change the result type or name a different spelling stay" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Len = u32;\n" ++
        "fn alias(e: u16) Len { const x: Len = @as(u32, e); return x; }\n" ++
        "fn wider(e: u16) u64 { return @as(u32, e); }\n" ++
        "fn failing(e: u16) !u32 { return @as(u32, e); }\n" ++
        "fn optional(e: u16) ?u32 { return @as(u32, e); }\n" ++
        "fn nested(e: u16) u32 { const S = struct { fn inner(v: u16) u64 { return @as(u32, v); } }; _ = S; return e; }\n" ++
        "fn peer(c: bool, e: u16) u32 { const x: u32 = if (c) @as(u32, e) else 7; return x + @as(u32, e); }\n" ++
        "test \"returns\" { return @as(u32, 1); }\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.needless_cast}, .warning));
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "a comment inside the cast withholds the fix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn f(e: u16) u32 {\n" ++
        "    return @as(\n" ++
        "        u32, // widened\n" ++
        "        e,\n" ++
        "    );\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.needless_cast}, .warning));
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(@as(usize, 0), found[0].fixes.len);
}
