//! `try` where no error can be returned. At container level, in a declaration
//! initializer or a `comptime` block, AstGen rejects it as "'try' outside
//! function scope". In a function whose declared return type is not an error
//! union, Sema rejects it ("function cannot return an error") as soon as the
//! operand can fail, which is reported when that is proven: an allocator call,
//! or a function of this file whose error set is visibly not empty.

const std = @import("std");
const Ast = std.zig.Ast;
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const tokens_util = @import("../../syntax/tokens.zig");

pub const rules = [_]types.Rule{.misplaced_try};

/// Where a `try` sits: in the body of a function, of a test, or neither.
const Owner = union(enum) {
    function: Ast.Node.Index,
    test_block,
    container,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.misplaced_try);
    if (level == .off) return;
    const tree = context.tree;
    if (tree.errors.len != 0) return;

    var bodies: std.AutoHashMapUnmanaged(usize, Owner) = .empty;
    defer bodies.deinit(context.allocator);
    var functions: std.StringHashMapUnmanaged(?Ast.Node.Index) = .empty;
    defer functions.deinit(context.allocator);
    for (0..tree.nodes.len) |raw_node| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        switch (tree.nodeTag(node)) {
            .fn_decl => {
                const body = tree.nodeData(node).node_and_node[1];
                try bodies.put(context.allocator, tree.nodeMainToken(body), .{ .function = node });
                const name = tree.tokenSlice(tree.nodeMainToken(tree.nodeData(node).node_and_node[0]) + 1);
                const entry = try functions.getOrPut(context.allocator, name);
                // A name declared twice is not proven to mean either function.
                entry.value_ptr.* = if (entry.found_existing) null else node;
            },
            .test_decl => {
                const body = tree.nodeData(node).opt_token_and_node[1];
                try bodies.put(context.allocator, tree.nodeMainToken(body), .test_block);
            },
            else => {},
        }
    }

    for (0..tree.nodes.len) |raw_node| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        if (tree.nodeTag(node) != .@"try") continue;
        const keyword = tree.nodeMainToken(node);
        switch (owner(context, &bodies, keyword)) {
            .test_block => {},
            .container => try reportOutsideFunction(context, level, node),
            .function => |function| {
                if (insideDefer(context, keyword)) continue;
                if (!provablyFails(context, &functions, tree.nodeData(node).node)) continue;
                try reportInfallibleFunction(context, level, node, function);
            },
        }
    }
}

/// The innermost function or test body around `keyword`, unless a container
/// declaration encloses it first.
fn owner(context: RuleRun, bodies: *const std.AutoHashMapUnmanaged(usize, Owner), keyword: usize) Owner {
    var brace = context.enclosingOpeningBrace(keyword);
    while (brace) |opening| : (brace = context.enclosingOpeningBrace(opening)) {
        if (bodies.get(opening)) |found| return found;
        if (context.opensContainer(opening)) return .container;
    }
    return .container;
}

/// Whether `keyword` belongs to a `defer` or `errdefer`, where AstGen reports
/// the `try` for that instead.
fn insideDefer(context: RuleRun, keyword: usize) bool {
    const tokens = context.tokens;
    const start = tokens_util.statementStart(tokens, keyword);
    if (tokens[start].tag == .keyword_defer or tokens[start].tag == .keyword_errdefer) return true;
    var brace = context.enclosingOpeningBrace(keyword);
    while (brace) |opening| : (brace = context.enclosingOpeningBrace(opening)) {
        if (opening == 0 or context.opensContainer(opening)) return false;
        if (tokens[opening - 1].tag == .keyword_defer or tokens[opening - 1].tag == .keyword_errdefer) return true;
    }
    return false;
}

fn nodeSpan(context: RuleRun, node: Ast.Node.Index) std.zig.Token.Loc {
    return .{
        .start = context.tokens[context.tree.firstToken(node)].loc.start,
        .end = context.tokens[context.tree.lastToken(node)].loc.end,
    };
}

fn reportOutsideFunction(context: RuleRun, level: types.Level, node: Ast.Node.Index) !void {
    const tree = context.tree;
    const tokens = context.tokens;
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    // `const value = try load();` evaluates at compile time, where
    // `catch unreachable` turns a failure into a compile error.
    const fixes: []const types.Fix = if (tokens[first - 1].tag == .equal and tokens[last + 1].tag == .semicolon)
        try context.singleFix(.{
            .title = "Assert success with 'catch unreachable'",
            .span = nodeSpan(context, node),
            .replacement = try context.allocator.print("{s} catch unreachable", .{tree.getNodeSource(tree.nodeData(node).node)}),
        })
    else
        &.{};
    try context.emit(.{
        .rule = .misplaced_try,
        .level = level,
        .span = nodeSpan(context, node),
        .message = "'try' outside function scope",
        .fixes = fixes,
    });
}

fn reportInfallibleFunction(context: RuleRun, level: types.Level, node: Ast.Node.Index, function: Ast.Node.Index) !void {
    const tree = context.tree;
    const tokens = context.tokens;
    var buffer: [1]Ast.Node.Index = undefined;
    const prototype = tree.fullFnProto(&buffer, tree.nodeData(function).node_and_node[0]) orelse return;
    const return_type = prototype.ast.return_type.unwrap() orelse return;
    const type_start = tree.firstToken(return_type);
    if (tokens[type_start - 1].tag == .bang or !notErrorUnion(context, return_type)) return;
    const foreign = if (prototype.extern_export_inline_token) |token| tokens[token].tag != .keyword_inline else false;
    // A C calling convention cannot return an error union.
    const fixes: []const types.Fix = if (foreign or prototype.ast.callconv_expr != .none) &.{} else try context.singleFix(.{
        .title = try context.allocator.print("Return '!{s}'", .{tree.getNodeSource(return_type)}),
        .span = .{ .start = tokens[type_start].loc.start, .end = tokens[type_start].loc.start },
        .replacement = "!",
    });
    const related = try context.allocator.alloc(types.RelatedSpan, 1);
    related[0] = .{ .span = nodeSpan(context, return_type), .message = "function cannot return an error" };
    try context.emit(.{
        .rule = .misplaced_try,
        .level = level,
        .span = nodeSpan(context, node),
        .message = try context.allocator.print(
            "'try' can fail here, but the function returns '{s}', which is not an error union",
            .{tree.getNodeSource(return_type)},
        ),
        .related = related,
        .fixes = fixes,
    });
}

/// Whether the return type `node` is spelled as something other than an
/// error union: a primitive, an optional, pointer or array type, or a
/// container declared in this file.
fn notErrorUnion(context: RuleRun, node: Ast.Node.Index) bool {
    const tree = context.tree;
    switch (tree.nodeTag(node)) {
        .optional_type, .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range, .array_type, .array_type_sentinel => return true,
        .identifier => {},
        else => return false,
    }
    const name = tree.tokenSlice(tree.nodeMainToken(node));
    const primitives = [_][]const u8{ "void", "bool", "type", "anyopaque" };
    for (primitives) |primitive| if (std.mem.eql(u8, name, primitive)) return true;
    if (tokens_util.primitiveNumberKind(name) != null) return true;
    const tokens = context.tokens;
    const binding = context.scopes.findBinding(tree.nodeMainToken(node)) orelse return false;
    const declaration = binding.token_index;
    if (tokens[declaration - 1].tag != .keyword_const or tokens[declaration + 1].tag != .equal) return false;
    var value = declaration + 2;
    if (tokens[value].tag == .keyword_extern or tokens[value].tag == .keyword_packed) value += 1;
    return switch (tokens[value].tag) {
        .keyword_struct, .keyword_enum, .keyword_union, .keyword_opaque => true,
        else => false,
    };
}

/// Allocator methods, whose error set always holds `OutOfMemory`.
const allocating_methods = [_][]const u8{ "alloc", "allocSentinel", "alignedAlloc", "create", "dupe", "dupeZ", "realloc" };

/// Whether the `try` operand `node` is a call whose error set is visibly not
/// empty, so the `try` can return an error.
fn provablyFails(context: RuleRun, functions: *const std.StringHashMapUnmanaged(?Ast.Node.Index), node: Ast.Node.Index) bool {
    const tree = context.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return false;
    const callee = call.ast.fn_expr;
    switch (tree.nodeTag(callee)) {
        .field_access => {
            const method = tree.tokenSlice(tree.nodeData(callee).node_and_token[1]);
            for (allocating_methods) |name| if (std.mem.eql(u8, method, name)) return true;
            return false;
        },
        .identifier => {
            const name = tree.nodeMainToken(callee);
            const function = (functions.get(tree.tokenSlice(name)) orelse return false) orelse return false;
            // The call must name that declaration, not an alias spelled alike.
            const binding = context.scopes.findBinding(name) orelse return false;
            if (binding.token_index != tree.nodeMainToken(tree.nodeData(function).node_and_node[0]) + 1) return false;
            return returnsNonEmptyErrorSet(context, function);
        },
        else => return false,
    }
}

/// Whether the function declaration `function` returns an error union whose
/// error set holds at least one error: a non-empty `error{...}` or
/// `anyerror`, a constant naming one, or an inferred set fed by
/// `return error.Name`.
fn returnsNonEmptyErrorSet(context: RuleRun, function: Ast.Node.Index) bool {
    const tree = context.tree;
    const tokens = context.tokens;
    const prototype_node, const body = tree.nodeData(function).node_and_node;
    var buffer: [1]Ast.Node.Index = undefined;
    const prototype = tree.fullFnProto(&buffer, prototype_node) orelse return false;
    const return_type = prototype.ast.return_type.unwrap() orelse return false;
    if (tokens[tree.firstToken(return_type) - 1].tag == .bang) {
        for (tree.firstToken(body)..tree.lastToken(body)) |index| {
            if (tokens[index].tag == .keyword_return and tokens[index + 1].tag == .keyword_error and tokens[index + 2].tag == .period) return true;
        }
        return false;
    }
    if (tree.nodeTag(return_type) != .error_union) return false;
    const error_set = tree.nodeData(return_type).node_and_node[0];
    return nonEmptyErrorSet(context, error_set);
}

fn nonEmptyErrorSet(context: RuleRun, node: Ast.Node.Index) bool {
    const tree = context.tree;
    const tokens = context.tokens;
    switch (tree.nodeTag(node)) {
        .error_set_decl => {
            const opening = tree.nodeMainToken(node) + 1;
            return tokens[opening + 1].tag == .identifier or tokens[opening + 1].tag == .doc_comment;
        },
        .identifier => {
            if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "anyerror")) return true;
            const binding = context.scopes.findBinding(tree.nodeMainToken(node)) orelse return false;
            const declaration = binding.token_index;
            if (tokens[declaration - 1].tag != .keyword_const or tokens[declaration + 1].tag != .equal or
                tokens[declaration + 2].tag != .keyword_error or tokens[declaration + 3].tag != .l_brace) return false;
            return tokens[declaration + 4].tag == .identifier;
        },
        else => return false,
    }
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.misplaced_try}, .@"error"));
}

test "try at container level and in functions that cannot fail reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\const Error = error{Missing};
        \\fn load() Error!u8 {
        \\    return error.Missing;
        \\}
        \\fn inferred(flag: bool) !u8 {
        \\    if (flag) return error.Invalid;
        \\    return 1;
        \\}
        \\const table = try load();
        \\const Config = struct {
        \\    value: u8 = 0,
        \\    comptime {
        \\        _ = try load();
        \\    }
        \\};
        \\fn count() usize {
        \\    const value = try load();
        \\    return value;
        \\}
        \\fn build(gpa: std.mem.Allocator) ?[]u8 {
        \\    return try gpa.alloc(u8, 4);
        \\}
        \\fn named() Config {
        \\    _ = try inferred(true);
        \\    return .{};
        \\}
        \\export fn exported() void {
        \\    _ = try load();
        \\}
    ;
    const found = try findingsFor(arena.allocator(), source);
    try support.expectSpans(source, found, &.{ "try load()", "try load()", "try load()", "try gpa.alloc(u8, 4)", "try inferred(true)", "try load()" });
    try std.testing.expectEqualStrings("'try' outside function scope", found[0].message);
    try std.testing.expectEqualStrings("load() catch unreachable", found[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("load() catch unreachable", found[1].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("'try' can fail here, but the function returns 'usize', which is not an error union", found[2].message);
    try std.testing.expectEqualStrings("!", found[2].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("Return '!?[]u8'", found[3].fixes[0].title);
    try std.testing.expectEqual(@as(usize, 0), found[5].fixes.len);
}

test "try in error-returning functions, tests and unproven operands stays clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\fn quiet() !void {}
        \\fn returns() error{A}!u8 {
        \\    return error.A;
        \\}
        \\fn ok() !u8 {
        \\    return try returns();
        \\}
        \\fn explicit() anyerror!void {
        \\    _ = try returns();
        \\}
        \\fn empty() void {
        \\    try quiet();
        \\}
        \\fn generic(writer: anytype) void {
        \\    try writer.print("x", .{});
        \\}
        \\fn aliased() Result {
        \\    return try returns();
        \\}
        \\const Result = anyerror!u8;
        \\test "fallible" {
        \\    _ = try returns();
        \\}
        \\fn nested() void {
        \\    const Inner = struct {
        \\        fn inner() !u8 {
        \\            return try returns();
        \\        }
        \\    };
        \\    _ = Inner;
        \\}
        \\fn signature() error{Oops}!void {
        \\    _ = try returns();
        \\}
    ;
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), source)).len);
}
