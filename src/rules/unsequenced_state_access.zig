const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.unsequenced_state_access);
    if (level == .off) return;

    for (context.tokens, 0..) |token, aggregate_start| {
        if (token.tag != .l_brace or aggregate_start == 0 or
            context.tokens[aggregate_start - 1].tag != .period) continue;
        const aggregate_end = context.matchingToken(aggregate_start, .l_brace, .r_brace) orelse continue;

        for (context.tokens[aggregate_start + 1 .. aggregate_end], aggregate_start + 1..) |candidate, receiver_index| {
            if (candidate.tag != .identifier or receiver_index + 3 >= aggregate_end or
                context.tokens[receiver_index + 1].tag != .period or
                context.tokens[receiver_index + 2].tag != .identifier or
                context.tokens[receiver_index + 3].tag != .l_paren or
                !stateChangingMethod(context.tokenText(receiver_index + 2))) continue;
            const binding = context.tokenText(receiver_index);
            if (!context.refersToBinding(receiver_index, binding) or
                !hasVisibleMutableDeclaration(context, binding, aggregate_start)) continue;
            const mutation_field = aggregateField(context.tokens, aggregate_start, receiver_index);
            const copy_index = copiedInSiblingField(context, binding, aggregate_start, aggregate_end, receiver_index, mutation_field) orelse continue;
            const related = try context.allocator.alloc(types.RelatedSpan, 1);
            related[0] = .{
                .span = context.tokens[copy_index].loc,
                .message = "this field copies the local state",
            };
            try context.emit(.{
                .rule = .unsequenced_state_access,
                .level = level,
                .span = context.tokens[receiver_index + 2].loc,
                .message = try std.fmt.allocPrint(
                    context.allocator,
                    "aggregate copies mutable local '{s}' in one field and calls state-changing method '{s}' in another; sequence the call before constructing the aggregate",
                    .{ binding, context.tokenText(receiver_index + 2) },
                ),
                .related = related,
            });
            break;
        }
    }
}

fn stateChangingMethod(method: []const u8) bool {
    const methods = [_][]const u8{
        "advance", "append", "appendSlice", "consume", "fetch", "insert", "next", "pop", "put", "read", "remove", "write",
    };
    for (methods) |candidate| if (std.mem.eql(u8, method, candidate)) return true;
    return false;
}

fn hasVisibleMutableDeclaration(context: RuleRun, binding: []const u8, before: usize) bool {
    var index = before;
    while (index > 1) {
        index -= 1;
        if (context.tokens[index].tag == .keyword_fn) return false;
        if (!context.tokenIs(index, binding) or index == 0) continue;
        const declaration_tag = context.tokens[index - 1].tag;
        if (declaration_tag == .keyword_var) return true;
        if (declaration_tag == .keyword_const) return false;
    }
    return false;
}

fn copiedInSiblingField(
    context: RuleRun,
    binding: []const u8,
    aggregate_start: usize,
    aggregate_end: usize,
    receiver_index: usize,
    mutation_field: usize,
) ?usize {
    for (context.tokens[aggregate_start + 1 .. aggregate_end], aggregate_start + 1..) |token, index| {
        if (index == receiver_index or token.tag != .identifier or
            !context.refersToBinding(index, binding) or
            aggregateField(context.tokens, aggregate_start, index) == mutation_field) continue;
        return index;
    }
    return null;
}

fn aggregateField(tokens: []const std.zig.Token, aggregate_start: usize, target: usize) usize {
    var field: usize = 0;
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    for (tokens[aggregate_start + 1 .. target]) |token| switch (token.tag) {
        .l_paren => parenthesis_depth += 1,
        .r_paren => parenthesis_depth -|= 1,
        .l_bracket => bracket_depth += 1,
        .r_bracket => bracket_depth -|= 1,
        .l_brace => brace_depth += 1,
        .r_brace => brace_depth -|= 1,
        .comma => if (parenthesis_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
            field += 1;
        },
        else => {},
    };
    return field;
}

test "aggregate fields do not copy and advance the same mutable local" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn init(source: []const u8) !Parser { var lexer = Lexer{ .source = source }; " ++
        "return .{ .lexer = lexer, .current = try lexer.next() }; }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(types.Rule.unsequenced_state_access, findings[0].rule);
    try std.testing.expectEqual(@as(usize, 1), findings[0].related.len);
}

test "sequenced mutation immutable values and observational methods stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn sequenced(source: []const u8) !Parser { var lexer = Lexer{ .source = source }; " ++
        "const current = try lexer.next(); return .{ .lexer = lexer, .current = current }; }\n" ++
        "fn immutable(lexer: Lexer) Pair { return .{ .left = lexer, .right = lexer.next() }; }\n" ++
        "fn observed() Pair { var lexer = Lexer{}; return .{ .left = lexer, .count = lexer.len() }; }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "unsequenced state access honors suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn init(source: []const u8) !Parser { var lexer = Lexer{ .source = source };\n" ++
        "// zig-analyzer: disable-next-line unsequenced-state-access\n" ++
        "return .{ .lexer = lexer, .current = try lexer.next() }; }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{
        .allocator = allocator,
        .source = source,
        .tokens = tokens,
        .configuration = types.Configuration.defaults(),
        .findings = &findings,
    });
    return try findings.toOwnedSlice(allocator);
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]const std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return try tokens.toOwnedSlice(allocator);
        try tokens.append(allocator, token);
    }
}
