const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const tokens_module = @import("../../syntax/tokens.zig");

pub const rules = [_]types.Rule{
    .prefer_expression_initializer,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_expression_initializer);
    if (level == .off) return;

    for (context.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_var or declaration_index + 4 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const initializer = undefinedInitializer(context, declaration_index + 2, declaration_end) orelse continue;
        if (initializer + 2 != declaration_end or !context.tokenIs(initializer + 1, "undefined")) continue;
        const expression_index = declaration_end + 1;
        if (expression_index >= context.tokens.len) continue;
        const name = context.tokenText(declaration_index + 1);
        const expr_info: struct { name: []const u8, end: usize } = switch (context.tokens[expression_index].tag) {
            .keyword_if => if (ifAssignsEveryBranch(context, expression_index, name)) |end|
                .{ .name = "if", .end = end }
            else
                continue,
            .keyword_switch => if (switchAssignsEveryProng(context, expression_index, name)) |end|
                .{ .name = "switch", .end = end }
            else
                continue,
            else => continue,
        };

        const scope_end = context.enclosingScopeEnd(declaration_index) orelse context.tokens.len;
        if (context.bindingMutatedAfter(expr_info.end + 1, scope_end, name)) continue;

        try context.emit(.{
            .rule = .prefer_expression_initializer,
            .level = level,
            .span = context.tokens[declaration_index + 1].loc,
            .message = try context.allocator.print(
                "'{s}' starts undefined and every {s} branch assigns it; initialize a const from the {s} expression",
                .{ name, expr_info.name, expr_info.name },
            ),
            .fixes = try initializerFix(context, declaration_index, initializer, expression_index, expr_info.end, scope_end),
        });
    }
}

/// `const x: T = if (c) a else b;`, or the `switch` with one value per prong,
/// in place of the undefined declaration and the statement assigning it. The
/// branches only assign `x`, no condition reads it and nothing mutates it
/// later, so `const` holds and each value keeps `T` as its result type.
/// Declined without a type annotation, for text that spans lines or holds a
/// comment, and when a later method call through `x` may need it mutable.
fn initializerFix(
    context: RuleRun,
    declaration_index: usize,
    initializer: usize,
    statement: usize,
    statement_end: usize,
    scope_end: usize,
) ![]const types.Fix {
    const tokens = context.tokens;
    const name = context.tokenText(declaration_index + 1);
    if (declaration_index == 0 or tokens[declaration_index + 2].tag != .colon or
        methodCalledAfter(context, statement_end + 1, scope_end, name)) return &.{};
    switch (tokens[declaration_index - 1].tag) {
        .semicolon, .l_brace, .r_brace => {},
        else => return &.{},
    }
    const span: std.zig.Token.Loc = .{ .start = tokens[declaration_index].loc.start, .end = tokens[statement_end].loc.end };
    if (tokens_module.containsComment(context.source[span.start..span.end])) return &.{};

    var text: std.Io.Writer.Allocating = .init(context.allocator);
    defer text.deinit();
    const writer = &text.writer;
    try writer.print("const {s} = ", .{context.source[tokens[declaration_index + 1].loc.start..tokens[initializer - 1].loc.end]});
    const written = if (tokens[statement].tag == .keyword_if)
        try writeIfValue(context, writer, statement)
    else
        try writeSwitchValue(context, writer, statement, tokens_module.lineIndentation(context.source, span.start));
    if (!written) return &.{};
    try writer.writeByte(';');
    return context.singleFix(.{
        .title = "Initialize a const from the expression",
        .span = span,
        .replacement = try text.toOwnedSlice(),
        .preferred = true,
    });
}

/// Writes `if (c) a else if (d) b else c` for an `if` chain whose every block
/// only assigns one value.
fn writeIfValue(context: RuleRun, writer: *std.Io.Writer, if_index: usize) !bool {
    var cursor = if_index;
    while (true) {
        const condition_end = context.matchingToken(cursor + 1, .l_paren, .r_paren) orelse return false;
        const then_end = context.matchingToken(condition_end + 1, .l_brace, .r_brace) orelse return false;
        try writer.print("if {s} {s} else ", .{
            singleLine(context, cursor + 1, condition_end) orelse return false,
            assignedValue(context, condition_end + 1, then_end) orelse return false,
        });
        const else_target = then_end + 2;
        if (context.tokens[else_target].tag == .keyword_if) {
            cursor = else_target;
            continue;
        }
        const else_end = context.matchingToken(else_target, .l_brace, .r_brace) orelse return false;
        try writer.writeAll(assignedValue(context, else_target, else_end) orelse return false);
        return true;
    }
}

/// Writes the `switch` with each prong's block replaced by its value, one
/// prong per line as `zig fmt` lays out every switch.
fn writeSwitchValue(context: RuleRun, writer: *std.Io.Writer, switch_index: usize, indentation: []const u8) !bool {
    const operand_end = context.matchingToken(switch_index + 1, .l_paren, .r_paren) orelse return false;
    const opening = operand_end + 1;
    const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse return false;
    try writer.print("switch {s} {{\n", .{singleLine(context, switch_index + 1, operand_end) orelse return false});
    var cursor = opening + 1;
    while (cursor < closing) {
        const arrow = topLevelArrow(context.tokens, cursor, closing) orelse return false;
        const body_end = context.matchingToken(arrow + 1, .l_brace, .r_brace) orelse return false;
        try writer.print("{s}    {s} => {s},\n", .{
            indentation,
            singleLine(context, cursor, arrow - 1) orelse return false,
            assignedValue(context, arrow + 1, body_end) orelse return false,
        });
        cursor = body_end + 2;
    }
    try writer.print("{s}}}", .{indentation});
    return true;
}

/// The value of the block `{ x = value; }` from `opening` to `closing`, when
/// it fits on one line and holds no nested `if` or loop whose `else` could
/// regroup inside the new expression.
fn assignedValue(context: RuleRun, opening: usize, closing: usize) ?[]const u8 {
    for (context.tokens[opening + 3 .. closing - 1]) |token| switch (token.tag) {
        .keyword_if, .keyword_while, .keyword_for => return null,
        else => {},
    };
    return singleLine(context, opening + 3, closing - 2);
}

/// Source of the tokens `[first, last]` when it fits on one line.
fn singleLine(context: RuleRun, first: usize, last: usize) ?[]const u8 {
    const text = context.source[context.tokens[first].loc.start..context.tokens[last].loc.end];
    return if (std.mem.findScalar(u8, text, '\n') == null) text else null;
}

/// Whether a reference to `name` in `[start, end)` calls a method through it
/// (`x.append(...)`, `x.inner.reset()`), which may take a pointer to a `var`.
fn methodCalledAfter(context: RuleRun, start: usize, end: usize, name: []const u8) bool {
    const tokens = context.tokens;
    for (start..@min(end, tokens.len)) |index| {
        if (!context.refersToBinding(index, name)) continue;
        var cursor = index + 1;
        var member = false;
        while (cursor + 1 < tokens.len) switch (tokens[cursor].tag) {
            .period => {
                if (tokens[cursor + 1].tag != .identifier) break;
                member = true;
                cursor += 2;
            },
            .l_bracket => cursor = (context.matchingToken(cursor, .l_bracket, .r_bracket) orelse break) + 1,
            else => break,
        };
        if (member and tokens[cursor].tag == .l_paren) return true;
    }
    return false;
}

fn undefinedInitializer(context: RuleRun, start: usize, end: usize) ?usize {
    for (context.tokens[start..end], start..) |token, index| if (token.tag == .equal) return index;
    return null;
}

fn ifAssignsEveryBranch(context: RuleRun, if_index: usize, name: []const u8) ?usize {
    if (if_index + 2 >= context.tokens.len or context.tokens[if_index + 1].tag != .l_paren) return null;
    const condition_end = context.matchingToken(if_index + 1, .l_paren, .r_paren) orelse return null;
    if (bindingReferenced(context, if_index + 2, condition_end, name)) return null;
    const then_start = condition_end + 1;
    if (then_start >= context.tokens.len or context.tokens[then_start].tag != .l_brace) return null;
    const then_end = context.matchingToken(then_start, .l_brace, .r_brace) orelse return null;
    if (!blockOnlyAssigns(context, then_start, then_end, name)) return null;
    if (then_end + 1 >= context.tokens.len or context.tokens[then_end + 1].tag != .keyword_else) return null;
    const else_target = then_end + 2;
    if (else_target >= context.tokens.len) return null;
    if (context.tokens[else_target].tag == .keyword_if) {
        return ifAssignsEveryBranch(context, else_target, name);
    }
    if (context.tokens[else_target].tag != .l_brace) return null;
    const else_end = context.matchingToken(else_target, .l_brace, .r_brace) orelse return null;
    if (!blockOnlyAssigns(context, else_target, else_end, name)) return null;
    return else_end;
}

fn switchAssignsEveryProng(context: RuleRun, switch_index: usize, name: []const u8) ?usize {
    if (switch_index + 2 >= context.tokens.len or context.tokens[switch_index + 1].tag != .l_paren) return null;
    const operand_end = context.matchingToken(switch_index + 1, .l_paren, .r_paren) orelse return null;
    if (bindingReferenced(context, switch_index + 2, operand_end, name)) return null;
    const opening = operand_end + 1;
    if (opening >= context.tokens.len or context.tokens[opening].tag != .l_brace) return null;
    const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse return null;

    var cursor = opening + 1;
    var prong_count: usize = 0;
    while (cursor < closing) {
        const arrow = topLevelArrow(context.tokens, cursor, closing) orelse return null;
        if (bindingReferenced(context, cursor, arrow, name)) return null;
        const body_start = arrow + 1;
        if (body_start >= closing or context.tokens[body_start].tag != .l_brace) return null;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse return null;
        if (!blockOnlyAssigns(context, body_start, body_end, name)) return null;
        prong_count += 1;
        cursor = body_end + 1;
        if (cursor < closing) {
            if (context.tokens[cursor].tag != .comma) return null;
            cursor += 1;
        }
    }
    if (prong_count >= 2) return closing;
    return null;
}

fn bindingReferenced(context: RuleRun, start: usize, end: usize, name: []const u8) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.refersToBinding(index, name)) return true;
    }
    return false;
}

fn blockOnlyAssigns(context: RuleRun, opening: usize, closing: usize, name: []const u8) bool {
    if (opening + 4 > closing or context.tokens[opening + 1].tag != .identifier or
        !context.tokenIs(opening + 1, name) or context.tokens[opening + 2].tag != .equal or
        context.tokens[closing - 1].tag != .semicolon) return false;
    for (context.tokens[opening + 3 .. closing - 1], opening + 3..) |token, index| {
        if (token.tag == .semicolon or context.refersToBinding(index, name)) return false;
    }
    return true;
}

fn topLevelArrow(tokens: []const std.zig.Token, start: usize, end: usize) ?usize {
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    for (tokens[start..end], start..) |token, index| switch (token.tag) {
        .l_paren => parenthesis_depth += 1,
        .r_paren => parenthesis_depth -|= 1,
        .l_bracket => bracket_depth += 1,
        .r_bracket => bracket_depth -|= 1,
        .l_brace => brace_depth += 1,
        .r_brace => brace_depth -|= 1,
        .equal_angle_bracket_right => if (parenthesis_depth == 0 and bracket_depth == 0 and brace_depth == 0) return index,
        else => {},
    };
    return null;
}

test "undefined locals assigned by every if branch prefer expression initialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "var value: u8 = undefined;\n" ++
        "if (ready) { value = 1; } else { value = 2; }\n" ++
        "use(value);";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(std.mem.find(u8, findings[0].message, "const") != null);
}

test "undefined locals assigned by every switch prong prefer expression initialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "var value: u8 = undefined;\n" ++
        "switch (mode) { .fast => { value = 1; }, .safe => { value = 2; } }\n" ++
        "use(value);";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(std.mem.find(u8, findings[0].message, "switch") != null);
}

test "partial and multi-statement assignments stay unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "var partial: u8 = undefined; if (ready) { partial = 1; }\n" ++
        "var prepared: u8 = undefined; if (ready) { prepare(); prepared = 1; } else { prepared = 2; }\n" ++
        "var self_read: u8 = undefined; if (self_read == 0) { self_read = 1; } else { self_read = 2; }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "undefined locals assigned by else if chain prefer expression initialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "var value: u8 = undefined;\n" ++
        "if (a) { value = 1; } else if (b) { value = 2; } else { value = 3; }\n" ++
        "use(value);";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "locals mutated later in scope stay unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "var value: u8 = undefined;\n" ++
        "if (ready) { value = 1; } else { value = 2; }\n" ++
        "value += 1;\n" ++
        "use(value);";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

/// The source after the fix of its one finding, checked to be formatted as
/// `zig fmt` renders it, or null when the finding offers no fix.
fn fixedFor(allocator: std.mem.Allocator, source: [:0]const u8) !?[]const u8 {
    const found = try findingsFor(allocator, source);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    if (found[0].fixes.len == 0) return null;
    const fixed = try allocator.dupeSentinel(u8, try support.applyFix(allocator, source, found[0].fixes[0]), 0);
    var tree = try std.zig.Ast.parse(allocator, fixed, .{ .mode = .zig });
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    try std.testing.expectEqualStrings(fixed, try tree.renderAlloc(allocator));
    return fixed;
}

test "an undefined local assigned by an if chain becomes a const if expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "fn pick(a: bool, b: bool) u32 {\n    const x: u32 = if (a) 1 else if (b and !a) 2 else 3;\n    return x;\n}\n",
        (try fixedFor(arena.allocator(), "fn pick(a: bool, b: bool) u32 {\n" ++
            "    var x: u32 = undefined;\n" ++
            "    if (a) {\n        x = 1;\n    } else if (b and !a) {\n        x = 2;\n    } else {\n        x = 3;\n    }\n" ++
            "    return x;\n}\n")).?,
    );
}

test "an undefined local assigned by every switch prong becomes a const switch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "fn pick(mode: Mode) u32 {\n" ++
            "    const x: u32 = switch (mode) {\n        .fast => 1,\n        .safe, .small => 2,\n        else => 3,\n    };\n" ++
            "    return x;\n}\n",
        (try fixedFor(arena.allocator(), "fn pick(mode: Mode) u32 {\n" ++
            "    var x: u32 = undefined;\n" ++
            "    switch (mode) {\n        .fast => {\n            x = 1;\n        },\n        .safe, .small => {\n            x = 2;\n        },\n" ++
            "        else => {\n            x = 3;\n        },\n    }\n" ++
            "    return x;\n}\n")).?,
    );
}

test "an expression initializer is not offered for shapes it cannot keep" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][:0]const u8{
        // No type for the const to carry.
        "fn f(c: bool) void { var x = undefined; if (c) { x = 1; } else { x = 2; } use(x); }",
        // A method may take a pointer to the local.
        "fn f(c: bool) void { var x: List = undefined; if (c) { x = a; } else { x = b; } x.append(1); }",
        "fn f(c: bool) void { var x: u8 = undefined; if (c) { x = 1; } else { x = 2; // two\n } use(x); }",
        "fn f(c: bool) void { var x: S = undefined; if (c) { x = .{\n.a = 1,\n}; } else { x = .{}; } use(x); }",
        "fn f(c: bool, d: bool) void { var x: u8 = undefined; if (c) { x = if (d) 1 else 2; } else { x = 3; } use(x); }",
        "fn f(c: bool) void { comptime var x: u8 = undefined; if (c) { x = 1; } else { x = 2; } use(x); }",
    }) |source| try std.testing.expectEqual(@as(?[]const u8, null), try fixedFor(arena.allocator(), source));
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.prefer_expression_initializer}, .information));
}
