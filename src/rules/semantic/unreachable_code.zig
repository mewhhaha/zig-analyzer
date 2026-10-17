//! Statements after `return`, `break`, `continue`, `unreachable`, `@panic`,
//! `@trap` or `@compileError` in the same block. AstGen rejects them as
//! "unreachable code"; the finding follows its rule exactly (declarations,
//! assignments, `defer` and loops after the diverting statement keep it
//! diverted, any other expression statement ends it) and uses its wording and
//! spans, so an editor that also shows the compiler's errors merges the two.

const std = @import("std");
const Ast = std.zig.Ast;
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const tokens_util = @import("../../syntax/tokens.zig");
const Binding = @import("../../syntax/scope.zig").Binding;

pub const rules = [_]types.Rule{.unreachable_code};

pub fn run(context: RuleRun) !void {
    const level = context.level(.unreachable_code);
    if (level == .off) return;
    const tree = context.tree;
    if (tree.errors.len != 0) return;
    for (0..tree.nodes.len) |raw_node| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        switch (tree.nodeTag(node)) {
            .block, .block_semicolon, .block_two, .block_two_semicolon => {},
            else => continue,
        }
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, node) orelse continue;
        var diverted: ?Ast.Node.Index = null;
        var fixes: ?[]const types.Fix = null;
        for (statements, 0..) |statement, index| {
            if (diverted) |diverting| {
                if (fixes == null) fixes = try removalFix(context, statements[index..]);
                try report(context, level, statement, diverting, fixes.?);
            }
            var inner = statement;
            while (tree.nodeTag(inner) == .grouped_expression) inner = tree.nodeData(inner).node_and_token[0];
            if (!keepsDiversion(tree.nodeTag(inner))) diverted = if (diverts(tree, inner)) inner else null;
        }
    }
}

/// Statements AstGen lowers without asking whether they are `noreturn`, so
/// a diversion before them stays in effect after them.
fn keepsDiversion(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .global_var_decl,
        .local_var_decl,
        .simple_var_decl,
        .aligned_var_decl,
        .assign_destructure,
        .@"defer",
        .@"errdefer",
        .assign,
        .assign_shl,
        .assign_shr,
        .assign_bit_and,
        .assign_bit_or,
        .assign_bit_xor,
        .assign_div,
        .assign_sub,
        .assign_sub_wrap,
        .assign_mod,
        .assign_add,
        .assign_add_wrap,
        .assign_mul,
        .assign_mul_wrap,
        .while_simple,
        .while_cont,
        .@"while",
        .for_simple,
        .@"for",
        => true,
        else => false,
    };
}

/// Whether the expression statement `node` is `noreturn` to AstGen.
fn diverts(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .@"return", .@"break", .@"continue", .unreachable_literal => true,
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            return std.mem.eql(u8, name, "@panic") or std.mem.eql(u8, name, "@trap") or
                std.mem.eql(u8, name, "@compileError");
        },
        else => false,
    };
}

fn nodeSpan(context: RuleRun, node: Ast.Node.Index) std.zig.Token.Loc {
    return .{
        .start = context.tokens[context.tree.firstToken(node)].loc.start,
        .end = context.tokens[context.tree.lastToken(node)].loc.end,
    };
}

fn report(context: RuleRun, level: types.Level, statement: Ast.Node.Index, diverting: Ast.Node.Index, fixes: []const types.Fix) !void {
    const related = try context.allocator.alloc(types.RelatedSpan, 1);
    related[0] = .{ .span = nodeSpan(context, diverting), .message = "control flow is diverted here" };
    try context.emit(.{
        .rule = .unreachable_code,
        .level = level,
        .span = nodeSpan(context, statement),
        .message = "unreachable code",
        .related = related,
        .fixes = fixes,
    });
}

/// Deleting the `dead` statements that follow a diversion, offered when they
/// fill whole lines and none holds the last use of a binding declared before.
fn removalFix(context: RuleRun, dead: []const Ast.Node.Index) ![]const types.Fix {
    const tree = context.tree;
    const tokens = context.tokens;
    const source = context.source;
    const first = tree.firstToken(dead[0]);
    var last = tree.lastToken(dead[dead.len - 1]);
    if (tokens[last + 1].tag == .semicolon) last += 1;
    const start = tokens[first].loc.start;
    const end = tokens[last].loc.end;
    if (std.mem.trim(u8, source[tokens_util.lineStart(source, start)..start], " \t").len != 0 or
        std.mem.trim(u8, source[end..tokens_util.lineEnd(source, end)], " \t\r\n").len != 0) return &.{};
    for (first..last + 1) |index| {
        // `break :outer` may be the only use of a label declared before.
        if ((tokens[index].tag == .keyword_break or tokens[index].tag == .keyword_continue) and
            tokens[index + 1].tag == .colon and !labelDeclaredIn(context, context.tokenText(index + 2), first, last)) return &.{};
        if (tokens[index].tag != .identifier or tokens[index - 1].tag == .period) continue;
        // The binding visible where the dead code starts; one declared inside
        // it cannot share the name, since locals do not shadow.
        const binding = context.scopes.findBindingNamed(context.tokenText(index), first) orelse continue;
        if (binding.token_index >= first) continue;
        // The dead code may hold the only mutation of a `var`.
        if (tokens[binding.token_index - 1].tag == .keyword_var and mayMutate(tokens, index)) return &.{};
        if (!usedOutside(context, binding, index, first, last)) return &.{};
    }
    return context.singleFix(.{
        .title = "Remove the unreachable code",
        .span = tokens_util.removedLinesSpan(source, start, end),
        .replacement = "",
    });
}

/// Whether the identifier at `index` may be written through: assigned,
/// indexed, dereferenced, addressed or used as a method receiver.
fn mayMutate(tokens: []const std.zig.Token, index: usize) bool {
    if (tokens[index - 1].tag == .ampersand) return true;
    return switch (tokens[index + 1].tag) {
        .period, .period_asterisk, .l_bracket => true,
        else => |tag| tokens_util.isAssignment(tag),
    };
}

/// Whether a label spelled `name` is declared in the tokens `[first, last]`.
fn labelDeclaredIn(context: RuleRun, name: []const u8, first: usize, last: usize) bool {
    const tokens = context.tokens;
    for (first..last) |index| {
        if (tokens[index].tag == .identifier and tokens[index + 1].tag == .colon and context.tokenIs(index, name) and
            (index == 0 or tokens[index - 1].tag != .colon)) return true;
    }
    return false;
}

/// Whether the binding that the identifier at `use` resolves to is referenced
/// in its scope outside the tokens `[first, last]`. Container members are
/// never unused errors, so they always count as used.
fn usedOutside(context: RuleRun, binding: Binding, use: usize, first: usize, last: usize) bool {
    const tokens = context.tokens;
    const declaration = binding.token_index;
    switch (tokens[declaration - 1].tag) {
        .keyword_const, .keyword_var, .keyword_fn => {
            const brace = context.enclosingOpeningBrace(declaration) orelse return true;
            if (context.opensContainer(brace)) return true;
        },
        else => {},
    }
    const name = context.tokenText(use);
    var index = declaration + 1;
    while (index < tokens.len and tokens[index].loc.start < binding.scope.end) : (index += 1) {
        if (index >= first and index <= last) continue;
        if (tokens[index].tag != .identifier or tokens[index - 1].tag == .period or !context.tokenIs(index, name)) continue;
        const resolved = context.scopes.findBinding(index) orelse continue;
        if (resolved.token_index == declaration) return true;
    }
    return false;
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.unreachable_code}, .@"error"));
}

test "statements after a diverting statement report as AstGen does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\fn early(flag: bool) u8 {
        \\    if (flag) {
        \\        return 1;
        \\        const unused: u8 = 2;
        \\        _ = unused;
        \\    }
        \\    return 3;
        \\}
        \\fn ended() void {
        \\    @panic("stop");
        \\    work();
        \\    work();
        \\}
        \\fn work() void {}
        \\fn loop(items: []const u8) void {
        \\    for (items) |_| {
        \\        continue;
        \\        unreachable;
        \\    }
        \\}
    ;
    const found = try findingsFor(arena.allocator(), source);
    try support.expectSpans(source, found, &.{ "const unused: u8 = 2", "_ = unused", "work()", "unreachable" });
    try std.testing.expectEqualStrings("unreachable code", found[0].message);
    try std.testing.expectEqualStrings("return 1", source[found[0].related[0].span.start..found[0].related[0].span.end]);
    try std.testing.expectEqualStrings(
        "        const unused: u8 = 2;\n        _ = unused;\n",
        source[found[0].fixes[0].edits[0].span.start..found[0].fixes[0].edits[0].span.end],
    );
    try std.testing.expectEqualStrings("    work();\n    work();\n", source[found[2].fixes[0].edits[0].span.start..found[2].fixes[0].edits[0].span.end]);
}

test "diversions inside branches, blocks and comptime stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\fn branches(flag: bool) u8 {
        \\    if (flag) return 1 else return 2;
        \\    return 3;
        \\}
        \\fn nested() u8 {
        \\    {
        \\        return 1;
        \\    }
        \\    comptime unreachable;
        \\    return 2;
        \\}
        \\fn exits() void {
        \\    std.process.exit(0);
        \\    work();
        \\}
        \\const std = @import("std");
        \\fn work() void {}
    ;
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), source)).len);
}

test "removing dead code that holds a binding's only use is not offered" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\fn last(value: u8) u8 {
        \\    const doubled = value * 2;
        \\    return 0;
        \\    _ = doubled;
        \\}
        \\fn mutation() u8 {
        \\    var count: u8 = 0;
        \\    const total = count;
        \\    return total;
        \\    count += 1;
        \\}
        \\fn label(items: []const u8) void {
        \\    outer: for (items) |_| {
        \\        return;
        \\        break :outer;
        \\    }
        \\}
    ;
    const found = try findingsFor(arena.allocator(), source);
    try support.expectSpans(source, found, &.{ "_ = doubled", "count += 1", "break :outer" });
    for (found) |finding| try std.testing.expectEqual(@as(usize, 0), finding.fixes.len);
}
