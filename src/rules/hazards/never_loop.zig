//! Loops whose body always leaves on the first iteration. When the body ends
//! with an unconditional `break` or `return` and nothing in it continues the
//! loop, every path through the body exits, so the loop runs at most once: an
//! `if` written as a loop, or a loop whose exit was meant to be conditional.

const std = @import("std");
const Ast = std.zig.Ast;
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{.never_loop};

pub fn run(context: RuleRun) !void {
    const level = context.level(.never_loop);
    if (level == .off) return;
    const tree = context.tree;
    for (0..tree.nodes.len) |raw_node| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        const loop = loopParts(tree, node) orelse continue;
        // An `else` branch makes the loop read as the `if`/`else` it is.
        if (loop.inline_token != null or loop.has_else) continue;
        const exit = finalStatement(tree, loop.body);
        const exit_text = switch (tree.nodeTag(exit)) {
            .@"return" => "return",
            .@"break" => exit: {
                const label, const value = tree.nodeData(exit).opt_token_and_opt_node;
                // `for (items) |item| break item;` computes a value on purpose,
                // and `while (true) { ...; break; }` is a breakable block.
                if (value != .none or breaksBodyBlock(context, loop.body, exit)) continue;
                if (label == .none and loop.unconditional) continue;
                break :exit "break";
            },
            .@"continue" => if (continuesLoop(context, loop, exit)) continue else "continue",
            else => continue,
        };
        if (bodyContinues(context, loop, tree.firstToken(loop.body), tree.lastToken(loop.body))) continue;
        const related = try context.allocator.alloc(types.RelatedSpan, 1);
        related[0] = .{ .span = context.tokens[tree.nodeMainToken(exit)].loc, .message = "every iteration ends here" };
        try context.emit(.{
            .rule = .never_loop,
            .level = level,
            .span = context.tokens[loop.keyword].loc,
            .message = try context.allocator.print(
                "this loop never repeats: its body ends with an unconditional '{s}' and nothing continues it",
                .{exit_text},
            ),
            .related = related,
        });
    }
}

const Loop = struct {
    keyword: usize,
    body: Ast.Node.Index,
    inline_token: ?Ast.TokenIndex,
    label_token: ?Ast.TokenIndex,
    has_else: bool,
    /// `while (true)`.
    unconditional: bool = false,
};

fn loopParts(tree: *const Ast, node: Ast.Node.Index) ?Loop {
    if (tree.fullWhile(node)) |loop| {
        const condition = loop.ast.cond_expr;
        return .{
            .keyword = loop.ast.while_token,
            .body = loop.ast.then_expr,
            .inline_token = loop.inline_token,
            .label_token = loop.label_token,
            .has_else = loop.ast.else_expr != .none,
            .unconditional = tree.nodeTag(condition) == .identifier and
                std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(condition)), "true"),
        };
    }
    if (tree.fullFor(node)) |loop| return .{
        .keyword = loop.ast.for_token,
        .body = loop.ast.then_expr,
        .inline_token = loop.inline_token,
        .label_token = loop.label_token,
        .has_else = loop.ast.else_expr != .none,
    };
    return null;
}

/// The last statement of the block `body`, or `body` itself when it is a
/// single statement.
fn finalStatement(tree: *const Ast, body: Ast.Node.Index) Ast.Node.Index {
    var buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, body) orelse return body;
    return if (statements.len == 0) body else statements[statements.len - 1];
}

/// Whether the `break` at `exit` leaves only the labeled block that forms the
/// loop body, as in `while (x) body: { ...; break :body; }`.
fn breaksBodyBlock(context: RuleRun, body: Ast.Node.Index, exit: Ast.Node.Index) bool {
    const label = context.tree.nodeData(exit).opt_token_and_opt_node[0].unwrap() orelse return false;
    const tokens = context.tokens;
    const opening = context.tree.nodeMainToken(body);
    if (tokens[opening].tag != .l_brace or opening < 2 or tokens[opening - 1].tag != .colon or
        tokens[opening - 2].tag != .identifier) return false;
    return std.mem.eql(u8, context.tokenText(opening - 2), context.tree.tokenSlice(label));
}

/// Whether the `continue` at `exit` repeats this loop rather than an outer one.
fn continuesLoop(context: RuleRun, loop: Loop, exit: Ast.Node.Index) bool {
    const label = context.tree.nodeData(exit).opt_token_and_opt_node[0].unwrap() orelse return true;
    const own = loop.label_token orelse return false;
    return std.mem.eql(u8, context.tree.tokenSlice(label), context.tree.tokenSlice(own));
}

/// Whether a `continue` in the body may start another iteration of `loop`: an
/// unlabeled one whose innermost braced loop is this one, or one naming this
/// loop's label.
fn bodyContinues(context: RuleRun, loop: Loop, first: usize, last: usize) bool {
    const tokens = context.tokens;
    for (first..last + 1) |index| {
        if (tokens[index].tag != .keyword_continue) continue;
        if (tokens[index + 1].tag == .colon) {
            const own = loop.label_token orelse continue;
            if (context.tokenIs(index + 2, context.tree.tokenSlice(own))) return true;
            continue;
        }
        if (!insideNestedLoop(context, loop.keyword, index)) return true;
    }
    return false;
}

/// Whether `index` lies in the braced body of a loop nested inside the loop
/// at `keyword`, so that an unlabeled `continue` there repeats that loop.
fn insideNestedLoop(context: RuleRun, keyword: usize, index: usize) bool {
    var brace = context.enclosingOpeningBrace(index);
    while (brace) |opening| : (brace = context.enclosingOpeningBrace(opening)) {
        if (opening < keyword) return false;
        const owner = context.loopKeyword(opening) orelse continue;
        return owner != keyword;
    }
    return false;
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.never_loop}, .warning));
}

test "loops whose body always exits report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\fn first(items: []const u8) ?u8 {
        \\    for (items) |item| {
        \\        if (item == 0) continue;
        \\        return item;
        \\    }
        \\    while (items.len > 1) {
        \\        if (items[0] == 0) break;
        \\        consume(items);
        \\        break;
        \\    }
        \\    outer: for (items) |a| {
        \\        while (a > 0) {
        \\            consume(items);
        \\            continue :outer;
        \\        }
        \\    }
        \\    for (items) |item| return item;
        \\    return null;
        \\}
        \\fn consume(_: []const u8) void {}
    ;
    const found = try findingsFor(arena.allocator(), source);
    try support.expectSpans(source, found, &.{ "while", "while", "for" });
    try std.testing.expectEqualStrings("break", source[found[0].related[0].span.start..found[0].related[0].span.end]);
}

test "loops that can repeat stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\fn scan(items: []const u8) ?u8 {
        \\    for (items) |item| {
        \\        if (item == 0) continue;
        \\        return item;
        \\    }
        \\    outer: while (true) {
        \\        for (items) |item| {
        \\            if (item == 1) continue :outer;
        \\        }
        \\        break;
        \\    }
        \\    while (items.len > 0) body: {
        \\        if (items[0] == 2) break :body;
        \\        break :body;
        \\    }
        \\    inline for (.{ 1, 2 }) |value| {
        \\        return value;
        \\    }
        \\    while (true) {
        \\        if (items.len == 0) break;
        \\    }
        \\    parse: while (true) {
        \\        if (items.len == 0) break;
        \\        if (items[0] == 3) break :parse;
        \\        break;
        \\    }
        \\    while (true) return retry(items) catch {
        \\        continue;
        \\    };
        \\    const head = for (items) |item| {
        \\        break item;
        \\    } else null;
        \\    var index = items.len;
        \\    while (index > 0) {
        \\        index -= 1;
        \\        return items[index];
        \\    } else return head;
        \\}
        \\fn retry(_: []const u8) !?u8 {
        \\    return null;
        \\}
    ;
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), source)).len);
}
