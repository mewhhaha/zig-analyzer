//! Names that resolve to nothing: calls, identifiers and labels checked against the lexical scope index.
const std = @import("std");

const syntax_scope = @import("../../syntax/scope.zig");
const tokenText = @import("../../syntax/tokens.zig").tokenText;
const tokenIs = @import("../../syntax/tokens.zig").tokenIs;
const matchingToken = @import("../../syntax/tokens.zig").matchingToken;
const rule_context = @import("../context.zig");
const RuleRun = rule_context.RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

const Configuration = types.Configuration;

pub const rules = [_]types.Rule{
    .unresolved_call,
    .unresolved_identifier,
    .unresolved_label,
};

pub fn run(context: RuleRun) !void {
    try findUnresolvedCalls(context);
    try findUnresolvedIdentifiers(context);
    try findUnresolvedLabels(context);
}

fn findUnresolvedCalls(context: RuleRun) !void {
    const source = context.source;
    const tokens = context.tokens;
    const level = context.level(.unresolved_call);
    if (level == .off) return;
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier or index + 1 >= tokens.len or tokens[index + 1].tag != .l_paren) continue;
        if (index > 0 and tokens[index - 1].tag == .period) continue;
        if (index >= 2 and tokens[index - 1].tag == .colon and
            (tokens[index - 2].tag == .keyword_break or tokens[index - 2].tag == .keyword_continue)) continue;
        const name = tokenText(source, token);
        if (std.zig.isPrimitive(name)) continue;
        if (context.scopes.findBinding(index)) |binding| {
            if (binding.kind != .non_callable) continue;
            try context.emit(.{
                .rule = .unresolved_call,
                .level = level,
                .span = token.loc,
                .message = try context.allocator.print("binding '{s}' is not callable", .{name}),
            });
            continue;
        }
        if (context.scopes.usingnamespaceMayProvideName(index)) continue;
        try context.emit(.{
            .rule = .unresolved_call,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print("call to unresolved function '{s}'", .{name}),
        });
    }
}

fn findUnresolvedIdentifiers(context: RuleRun) !void {
    const source = context.source;
    const tokens = context.tokens;
    const level = context.level(.unresolved_identifier);
    if (level == .off) return;

    for (0..context.tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        if (context.tree.nodeTag(node) != .identifier) continue;
        const token_index: usize = context.tree.nodeMainToken(node);
        if (token_index >= tokens.len) continue;
        const token = tokens[token_index];
        const name = tokenText(source, token);
        if (std.mem.eql(u8, name, "_") or std.zig.isPrimitive(name) or
            context.scopes.findBinding(token_index) != null or
            syntax_scope.isContainerFieldDeclaration(tokens, token_index) or
            containerHeaderResolvesToNestedDeclaration(source, tokens, token_index, name)) continue;
        // Field names and enum literals are resolved through their receiver or
        // result type. Calls retain the more specific unresolved-call finding.
        if (token_index > 0 and tokens[token_index - 1].tag == .period) continue;
        if (token_index + 1 < tokens.len and tokens[token_index + 1].tag == .l_paren) continue;
        if (context.scopes.usingnamespaceMayProvideName(token_index)) continue;

        try context.emit(.{
            .rule = .unresolved_identifier,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print("use of unresolved identifier '{s}'", .{name}),
        });
    }
}

fn containerHeaderResolvesToNestedDeclaration(
    source: []const u8,
    tokens: []const std.zig.Token,
    identifier_index: usize,
    name: []const u8,
) bool {
    var container_keyword: ?usize = null;
    var cursor = identifier_index;
    while (cursor > 0 and identifier_index - cursor < 32) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => {
                container_keyword = cursor;
                break;
            },
            .semicolon, .l_brace, .r_brace, .equal => return false,
            else => {},
        }
    }
    if (container_keyword == null) return false;

    var opening = identifier_index + 1;
    while (opening < tokens.len and tokens[opening].tag != .l_brace) : (opening += 1) {
        if (tokens[opening].tag == .semicolon) return false;
    }
    if (opening == tokens.len) return false;
    const closing = matchingToken(tokens, opening, .l_brace, .r_brace) orelse return false;

    var depth: usize = 0;
    for (tokens[opening + 1 .. closing], opening + 1..) |token, index| {
        switch (token.tag) {
            .l_brace => depth += 1,
            .r_brace => depth -|= 1,
            .keyword_const, .keyword_var, .keyword_fn => if (depth == 0 and index + 1 < closing and
                tokens[index + 1].tag == .identifier and tokenIs(source, tokens[index + 1], name)) return true,
            else => {},
        }
    }
    return false;
}

fn findUnresolvedLabels(context: RuleRun) !void {
    const source = context.source;
    const tokens = context.tokens;
    const level = context.level(.unresolved_label);
    if (level == .off) return;
    var labels: ?LabelScopes = null;
    defer if (labels) |*known| known.deinit(context.allocator);
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier or index < 2 or tokens[index - 1].tag != .colon or
            (tokens[index - 2].tag != .keyword_break and tokens[index - 2].tag != .keyword_continue)) continue;
        const name = tokenText(source, token);
        if (labels == null) labels = try LabelScopes.init(context);
        if (labels.?.visible(name, index)) continue;
        try context.emit(.{
            .rule = .unresolved_label,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print("branch targets unresolved label '{s}'", .{name}),
        });
    }
}

/// The token ranges in which each label declared in the file is visible.
const LabelScopes = struct {
    scopes: std.StringHashMapUnmanaged(std.ArrayList(Range)) = .empty,

    /// Tokens strictly between `start` and `end`.
    const Range = struct { start: usize, end: usize };

    fn init(context: RuleRun) !LabelScopes {
        const tokens = context.tokens;
        var labels: LabelScopes = .{};
        errdefer labels.deinit(context.allocator);
        for (tokens, 0..) |token, index| {
            if (token.tag != .identifier or index + 2 >= tokens.len or tokens[index + 1].tag != .colon) continue;
            const construct = index + 2;
            switch (tokens[construct].tag) {
                .l_brace, .keyword_while, .keyword_for, .keyword_switch, .keyword_inline => {},
                else => continue,
            }
            const entry = try labels.scopes.getOrPut(context.allocator, tokenText(context.source, token));
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            if (tokens[construct].tag != .l_brace) {
                if (bodyAfterHeader(context, construct)) |body| {
                    if (context.matchingToken(body, .l_brace, .r_brace)) |body_end| {
                        try entry.value_ptr.append(context.allocator, .{ .start = body, .end = body_end });
                    }
                }
            }
            if (labeledConstructEnd(context, construct)) |end| {
                try entry.value_ptr.append(context.allocator, .{ .start = construct, .end = end });
            }
        }
        return labels;
    }

    fn deinit(labels: *LabelScopes, allocator: std.mem.Allocator) void {
        var lists = labels.scopes.valueIterator();
        while (lists.next()) |list| list.deinit(allocator);
        labels.scopes.deinit(allocator);
    }

    fn visible(labels: LabelScopes, name: []const u8, use_index: usize) bool {
        const ranges = labels.scopes.get(name) orelse return false;
        for (ranges.items) |range| if (use_index > range.start and use_index < range.end) return true;
        return false;
    }
};

/// The `{` opening the body of the `while`, `for`, `switch` or `inline`
/// construct at `construct`: the first brace outside parentheses and brackets.
fn bodyAfterHeader(context: RuleRun, construct: usize) ?usize {
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    for (context.tokens[construct + 1 ..], construct + 1..) |token, cursor| switch (token.tag) {
        .l_paren => parenthesis_depth += 1,
        .r_paren => parenthesis_depth -|= 1,
        .l_bracket => bracket_depth += 1,
        .r_bracket => bracket_depth -|= 1,
        .l_brace => if (parenthesis_depth == 0 and bracket_depth == 0) return cursor,
        else => {},
    };
    return null;
}

fn labeledConstructEnd(context: RuleRun, construct: usize) ?usize {
    const tokens = context.tokens;
    if (tokens[construct].tag == .l_brace) return context.matchingToken(construct, .l_brace, .r_brace);
    var cursor = construct + 1;
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    while (cursor < tokens.len) : (cursor += 1) {
        switch (tokens[cursor].tag) {
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .l_bracket => bracket_depth += 1,
            .r_bracket => bracket_depth -|= 1,
            .l_brace => if (parenthesis_depth == 0 and bracket_depth == 0) {
                const body_end = context.matchingToken(cursor, .l_brace, .r_brace) orelse return null;
                if (body_end + 2 < tokens.len and tokens[body_end + 1].tag == .keyword_else) {
                    const else_start = body_end + 2;
                    if (tokens[else_start].tag == .l_brace) {
                        return context.matchingToken(else_start, .l_brace, .r_brace);
                    }
                    if (else_start + 2 < tokens.len and tokens[else_start].tag == .identifier and
                        tokens[else_start + 1].tag == .colon and tokens[else_start + 2].tag == .l_brace)
                    {
                        return context.matchingToken(else_start + 2, .l_brace, .r_brace);
                    }
                    return context.statementEnd(else_start);
                }
                return body_end;
            },
            .semicolon => if (parenthesis_depth == 0 and bracket_depth == 0) return cursor,
            else => {},
        }
    }
    return null;
}

test "renamed declarations report their unresolved type references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const MessagePool = @import(\"message_pool\");\n" ++
        "const Mssage = MessagePool.Message;\n" ++
        "fn toMessage(target: *Message.Prepare) void { _ = target; }\n" ++
        "const Pending = struct { message: ?*Message.Request = null };\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var unresolved_count: usize = 0;
    for (found) |finding| if (finding.rule == .unresolved_identifier) {
        unresolved_count += 1;
        try std.testing.expectEqualStrings("Message", source[finding.span.start..finding.span.end]);
        try std.testing.expect(std.mem.find(u8, finding.message, "unresolved identifier 'Message'") != null);
    };
    try std.testing.expectEqual(@as(usize, 2), unresolved_count);
}

test "resolved bindings and qualified members do not report unresolved identifiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "const Entry = struct { value: u8 };\n" ++
        "fn read(entry: Entry, maybe: ?u8, pair: struct { u8, u8 }) !u8 {\n" ++
        "    const .{ first, second } = pair;\n" ++
        "    const third, const fourth = pair;\n" ++
        "    if (maybe) |value| return entry.value + value + first + second + third + fourth;\n" ++
        "    return error.Missing;\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .unresolved_identifier);
}

test "container tags declared inside their container resolve in the header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Value = union(Key) { item: u8, pub const Key = enum { item } };\n" ++
        "const Handle = enum(Backing) { root, pub const Backing = u16 };\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .unresolved_identifier);
}

test "generic parameters remain visible after switch return types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Options = struct {};\n" ++
        "fn encode(data: anytype, opts: Options) switch (@TypeOf(data)) { []u8 => u8, else => void } {\n" ++
        "    _ = data;\n" ++
        "    _ = opts;\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .unresolved_identifier);
}

test "unresolved calls keep their specific diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn run() void { missing(); }\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var call_count: usize = 0;
    for (found) |finding| switch (finding.rule) {
        .unresolved_call => call_count += 1,
        .unresolved_identifier => return error.TestUnexpectedResult,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), call_count);
}

test "unresolved names respect lexical scopes and declaration order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn first() void { _ = later; _ = foreign; const later = 1; }\n" ++
        "fn second() void { const foreign = 1; _ = foreign; }\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var unresolved_count: usize = 0;
    for (found) |finding| {
        if (finding.rule == .unresolved_identifier) unresolved_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), unresolved_count);
}

test "obvious value bindings cannot be called" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "const run = 1; fn main() void { run(); }\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var non_callable_count: usize = 0;
    for (found) |finding| {
        if (finding.rule == .unresolved_call and
            std.mem.find(u8, finding.message, "not callable") != null) non_callable_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), non_callable_count);
}

test "named branches require an enclosing label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run() void { outer: for ([_]u8{ 1, 2 }) |_| { break :outer; } break :missing; }\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var label_count: usize = 0;
    for (found) |finding| {
        if (finding.rule == .unresolved_label) label_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), label_count);
}

test "labels are visible only inside their own construct and after their declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(flag: bool) void {\n" ++
        "    break :early;\n" ++
        "    early: { break :early; }\n" ++
        "    sibling: { _ = flag; }\n" ++
        "    break :sibling;\n" ++
        "    loop: while (flag) { if (flag) { break :loop; } continue :loop; }\n" ++
        "    after: switch (flag) { true => break :after, false => {} }\n" ++
        "    break :loop;\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var unresolved: [4]usize = undefined;
    var count: usize = 0;
    for (found) |finding| {
        if (finding.rule != .unresolved_label) continue;
        unresolved[count] = std.mem.countScalar(u8, source[0..finding.span.start], '\n') + 1;
        count += 1;
    }
    try std.testing.expectEqualSlices(usize, &.{ 2, 5, 8 }, unresolved[0..count]);
}

test "breaks resolve labels on for expressions with else clauses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const all_lower = all_lower: for (\"ABC\") |c| { if (c == 'A') break :all_lower false; } else break :all_lower true;\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .unresolved_label);
}

test "breaks resolve labels around for switch expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Mode = enum { first }; fn run(modes: []Mode) void { find_mode: for (modes) |mode| switch (mode) { .first => { break :find_mode; } } else {} }\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .unresolved_label);
}

test "breaks resolve labels on for expressions with labeled else blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn find(values: []u8) usize { return blk: for (values, 0..) |value, index| { if (value == 1) break :blk index; } else fallback: { break :fallback 0; }; }\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .unresolved_label);
}

test "breaks resolve a labeled for body when its else expression ends a switch prong" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Value = union(enum) { one: []const bool }; " ++
        "fn contains(value: Value) bool { return switch (value) { " ++
        ".one => |items| found: for (items) |item| { if (item) break :found true; } else false, " ++
        "}; }\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());

    for (found) |finding| try std.testing.expect(finding.rule != .unresolved_label);
}
