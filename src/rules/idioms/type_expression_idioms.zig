//! Type expressions that repeat what the result location already establishes, and initializers that restate their result type.
const std = @import("std");

const tokenText = @import("../../syntax/tokens.zig").tokenText;
const tokenIs = @import("../../syntax/tokens.zig").tokenIs;
const containsComment = @import("../../syntax/tokens.zig").containsComment;
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

const Ast = std.zig.Ast;
const Node = Ast.Node;
const Fix = types.Fix;

pub const rules = [_]types.Rule{
    .redundant_type_qualification,
    .prefer_anonymous_initializer,
};

pub fn run(context: RuleRun) !void {
    try findTypeExpressionIdioms(context);
    try findReturnedInitializers(context);
}

/// `return T{ ... }` from a function whose result is `T`, `!T`, `E!T` or `?T`
/// (or both wrappers): the return type is the initializer's result location,
/// so `.{` names the same type. The type expressions must be spelled the same,
/// which Zig's ban on shadowing makes them the same type; a returned value of
/// another type that merely coerces is left alone.
fn findReturnedInitializers(context: RuleRun) !void {
    const level = context.level(.prefer_anonymous_initializer);
    if (level == .off) return;
    const tree = context.tree;
    // A recovered tree can attach an initializer to the wrong operand.
    if (tree.errors.len != 0) return;
    // Opening brace of each function body, to the payload of its return type.
    var payloads: std.AutoHashMapUnmanaged(Ast.TokenIndex, Node.Index) = .empty;
    defer payloads.deinit(context.allocator);
    for (0..tree.nodes.len) |raw_node| {
        const node: Node.Index = @fromBackingInt(@intCast(raw_node));
        if (tree.nodeTag(node) != .fn_decl) continue;
        var buffer: [1]Node.Index = undefined;
        const prototype = tree.fullFnProto(&buffer, node) orelse continue;
        const return_type = prototype.ast.return_type.unwrap() orelse continue;
        const body = tree.nodeData(node).node_and_node[1];
        try payloads.put(context.allocator, tree.nodeMainToken(body), returnPayload(tree, return_type));
    }
    if (payloads.count() == 0) return;
    for (0..tree.nodes.len) |raw_node| {
        const node: Node.Index = @fromBackingInt(@intCast(raw_node));
        if (tree.nodeTag(node) != .@"return") continue;
        const operand = tree.nodeData(node).opt_node.unwrap() orelse continue;
        var buffer: [2]Node.Index = undefined;
        const type_expression, const lbrace = if (tree.fullStructInit(&buffer, operand)) |initializer|
            .{ initializer.ast.type_expr.unwrap() orelse continue, initializer.ast.lbrace }
        else if (tree.fullArrayInit(&buffer, operand)) |initializer|
            .{ initializer.ast.type_expr.unwrap() orelse continue, initializer.ast.lbrace }
        else
            continue;
        const payload = enclosingPayload(context, &payloads, tree.nodeMainToken(node)) orelse continue;
        if (!sameTokens(tree, payload, type_expression)) continue;
        const start = tree.tokenStart(tree.firstToken(type_expression));
        const type_end = tree.tokenStart(tree.lastToken(type_expression)) + tree.tokenSlice(tree.lastToken(type_expression)).len;
        const rewritten: std.zig.Token.Loc = .{ .start = start, .end = tree.tokenStart(lbrace) + 1 };
        if (containsComment(context.source[rewritten.start..rewritten.end])) continue;
        const fixes = try Fix.single(context.allocator, .{
            .title = "Use an anonymous initializer",
            .span = rewritten,
            .replacement = ".{",
            .preferred = true,
            .fix_all = true,
        });
        try context.emit(.{
            .rule = .prefer_anonymous_initializer,
            .level = level,
            .span = .{ .start = start, .end = type_end },
            .message = try context.allocator.print("initializer repeats return type '{s}'", .{context.source[start..type_end]}),
            .fixes = fixes,
        });
    }
}

/// The type a `return` result location gives an initializer: `T` from `T`,
/// `!T`, `E!T`, `?T` and `E!?T`.
fn returnPayload(tree: *const Ast, return_type: Node.Index) Node.Index {
    var payload = return_type;
    if (tree.nodeTag(payload) == .error_union) payload = tree.nodeData(payload).node_and_node[1];
    if (tree.nodeTag(payload) == .optional_type) payload = tree.nodeData(payload).node;
    return payload;
}

/// The return-type payload of the innermost function whose body holds `token`.
fn enclosingPayload(context: RuleRun, payloads: *const std.AutoHashMapUnmanaged(Ast.TokenIndex, Node.Index), token: Ast.TokenIndex) ?Node.Index {
    var brace = context.scopes.enclosingOpeningBrace(token);
    while (brace) |opening| : (brace = context.scopes.enclosingOpeningBrace(opening)) {
        if (payloads.get(@intCast(opening))) |payload| return payload;
    }
    return null;
}

fn sameTokens(tree: *const Ast, left: Node.Index, right: Node.Index) bool {
    const left_first = tree.firstToken(left);
    const right_first = tree.firstToken(right);
    const count = tree.lastToken(left) - left_first;
    if (tree.lastToken(right) - right_first != count) return false;
    for (0..count + 1) |offset| {
        const left_token: Ast.TokenIndex = @intCast(left_first + offset);
        const right_token: Ast.TokenIndex = @intCast(right_first + offset);
        if (!std.mem.eql(u8, tree.tokenSlice(left_token), tree.tokenSlice(right_token))) return false;
    }
    return true;
}

fn findTypeExpressionIdioms(context: RuleRun) !void {
    const source = context.source;
    const tokens = context.tokens;
    const qualification_level = context.level(.redundant_type_qualification);
    const initializer_level = context.level(.prefer_anonymous_initializer);
    if (qualification_level == .off and initializer_level == .off) return;
    for (tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 6 >= tokens.len or
            tokens[declaration_index + 1].tag != .identifier or tokens[declaration_index + 2].tag != .colon or
            tokens[declaration_index + 3].tag != .identifier or tokens[declaration_index + 4].tag != .equal or
            tokens[declaration_index + 5].tag != .identifier or
            !tokenIs(source, tokens[declaration_index + 3], tokenText(source, tokens[declaration_index + 5]))) continue;
        const type_name = tokenText(source, tokens[declaration_index + 3]);
        if (qualification_level != .off and declaration_index + 7 < tokens.len and
            tokens[declaration_index + 6].tag == .period and tokens[declaration_index + 7].tag == .identifier)
        {
            const fixes = try Fix.single(context.allocator, .{
                .title = "Use inferred enum literal",
                .span = .{ .start = tokens[declaration_index + 5].loc.start, .end = tokens[declaration_index + 7].loc.end },
                .replacement = try context.allocator.print(".{s}", .{tokenText(source, tokens[declaration_index + 7])}),
                .preferred = true,
                .fix_all = true,
            });
            try context.emit(.{
                .rule = .redundant_type_qualification,
                .level = qualification_level,
                .span = tokens[declaration_index + 5].loc,
                .message = try context.allocator.print("type '{s}' is already established by the result location", .{type_name}),
                .fixes = fixes,
            });
        } else if (initializer_level != .off and tokens[declaration_index + 6].tag == .l_brace) {
            const fixes = try Fix.single(context.allocator, .{
                .title = "Use an anonymous initializer",
                .span = .{ .start = tokens[declaration_index + 5].loc.start, .end = tokens[declaration_index + 6].loc.end },
                .replacement = ".{",
                .preferred = true,
                .fix_all = true,
            });
            try context.emit(.{
                .rule = .prefer_anonymous_initializer,
                .level = initializer_level,
                .span = tokens[declaration_index + 5].loc,
                .message = try context.allocator.print("initializer repeats result type '{s}'", .{type_name}),
                .fixes = fixes,
            });
        }
    }
}

test "qualification and initializers repeating the result type are reported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Mode = enum { fast, safe };\n" ++
        "const Options = struct { count: u32 };\n" ++
        "fn inspect(pointer: *u32) void {\n" ++
        "    const mode: Mode = Mode.fast;\n" ++
        "    const options: Options = Options{ .count = pointer.* };\n" ++
        "    _ = mode; _ = options;\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{ .redundant_type_qualification, .prefer_anonymous_initializer }, .information));
    try support.expectRules(found, &.{ .redundant_type_qualification, .prefer_anonymous_initializer });
}

test "returned initializers repeating the return type or its payload are reported with a fix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Point = struct {\n" ++
        "    x: i32 = 0,\n" ++
        "    const Self = @This();\n" ++
        "    fn init() Self { return Self{ .x = 1 }; }\n" ++
        "    fn here() @This() { return @This(){}; }\n" ++
        "    fn parse() !Point { return Point{ .x = 2 }; }\n" ++
        "    fn find() ?Point { return Point{}; }\n" ++
        "    fn load() error{Bad}!?Point { return Point { .x = 3 }; }\n" ++
        "};\n" ++
        "fn pair() [2]u8 { return [2]u8{ 1, 2 }; }\n" ++
        "fn make(comptime T: type) T { return T{}; }\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_anonymous_initializer}, .information));
    try support.expectSpans(source, found, &.{ "Self", "@This()", "Point", "Point", "Point", "[2]u8", "T" });
    for (found) |finding| {
        try std.testing.expect(finding.fixes[0].fix_all);
        try std.testing.expectEqualStrings(".{", finding.fixes[0].edits[0].replacement);
    }
    const edit = found[4].fixes[0].edits[0];
    try std.testing.expectEqualStrings("Point {", source[edit.span.start..edit.span.end]);
}

test "returned initializers of another type, nested functions and non-initializer operands are left alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Point = struct { x: i32 = 0, fn moved(p: Point) Point { return p; } };\n" ++
        "const Alias = Point;\n" ++
        "const Other = struct { p: Point = .{} };\n" ++
        "fn coerced() Alias { return Point{}; }\n" ++
        "fn chained() Point { return (Point{}).moved(); }\n" ++
        "fn pointer() *const Point { return &Point{}; }\n" ++
        "fn grouped() Point { return (Point{}); }\n" ++
        "fn outer() Point {\n" ++
        "    const Inner = struct { fn make() Other { return Point{}; } };\n" ++
        "    _ = Inner;\n" ++
        "    return .{};\n" ++
        "}\n" ++
        "fn generic(comptime T: type, value: anytype) T { const V = @TypeOf(value); return V{}; }\n" ++
        "fn commented() Point { return Point // keep\n{}; }\n" ++
        "test { _ = Point{}; }\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_anonymous_initializer}, .information));
    try std.testing.expectEqual(@as(usize, 0), found.len);
}
