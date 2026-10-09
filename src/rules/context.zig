const std = @import("std");
const syntax_scope = @import("../syntax/scope.zig");
const tokens_util = @import("../syntax/tokens.zig");
const types = @import("types.zig");

/// Token positions of a function with a body.
pub const FunctionRange = struct {
    parameters_start: usize,
    parameters_end: usize,
    body_start: usize,
    body_end: usize,
};

pub const RuleRun = struct {
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    configuration: types.Configuration,
    findings: *std.ArrayList(types.Finding),
    /// Parsed once per analysis; the tree may carry parse errors.
    tree: *const std.zig.Ast,
    /// Scope index over `tokens`, built once per analysis like `tree`.
    scopes: *const syntax_scope.Index,
    /// Shapes the compiler resolved for names the source does not declare.
    resolved_shapes: []const types.ResolvedShape = &.{},
    /// Members the file's top-level imports expose, resolved by the caller.
    module_members: []const types.ModuleMembers = &.{},

    pub fn level(context: RuleRun, rule: types.Rule) types.Level {
        return context.configuration.level(rule);
    }

    /// Records the finding unless its level is off. Suppression directives are
    /// applied once over all findings by the pipeline driver.
    pub fn emit(context: RuleRun, finding: types.Finding) !void {
        if (finding.level == .off) return;
        try context.findings.append(context.allocator, finding);
    }

    /// A fix list holding one fix with one edit.
    pub fn singleFix(context: RuleRun, spec: types.Fix.Single) ![]const types.Fix {
        return types.Fix.single(context.allocator, spec);
    }

    pub fn tokenText(context: RuleRun, index: usize) []const u8 {
        return tokens_util.tokenText(context.source, context.tokens[index]);
    }

    pub fn tokenIs(context: RuleRun, index: usize, expected: []const u8) bool {
        return index < context.tokens.len and tokens_util.tokenIs(context.source, context.tokens[index], expected);
    }

    pub fn refersToBinding(context: RuleRun, index: usize, name: []const u8) bool {
        return tokenRefersToBinding(context.source, context.tokens, index, name);
    }

    pub fn matchingToken(
        context: RuleRun,
        opening_index: usize,
        opening_tag: std.zig.Token.Tag,
        closing_tag: std.zig.Token.Tag,
    ) ?usize {
        std.debug.assert(context.tokens[opening_index].tag == opening_tag);
        const closing = context.scopes.matchingToken(opening_index) orelse return null;
        std.debug.assert(context.tokens[closing].tag == closing_tag);
        return closing;
    }

    pub fn statementEnd(context: RuleRun, start: usize) ?usize {
        return context.scopes.statementEnd(start);
    }

    pub fn enclosingOpeningBrace(context: RuleRun, index: usize) ?usize {
        return context.scopes.enclosingOpeningBrace(index);
    }

    pub fn enclosingScopeEnd(context: RuleRun, index: usize) ?usize {
        return context.scopes.enclosingScopeEnd(index);
    }

    pub fn topLevelComma(context: RuleRun, start: usize, end: usize) ?usize {
        return tokens_util.topLevelComma(context.tokens, start, end);
    }

    pub fn threeArguments(context: RuleRun, opening: usize, closing: usize) ?[3]tokens_util.Range {
        return tokens_util.threeArguments(context.tokens, opening, closing);
    }

    /// Whether an identifier spelled `name` occurs in `[start, end)`.
    pub fn rangeContainsName(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
        for (context.tokens[start..end], start..) |token, index| {
            if (token.tag == .identifier and context.tokenIs(index, name)) return true;
        }
        return false;
    }

    /// First identifier spelled `name` in `[start, end)`.
    pub fn findIdentifier(context: RuleRun, start: usize, end: usize, name: []const u8) ?usize {
        for (context.tokens[start..end], start..) |token, index| {
            if (token.tag == .identifier and context.tokenIs(index, name)) return index;
        }
        return null;
    }

    /// Parameter, body, and bracket positions of the function whose `fn` token
    /// is `function_index`; null for declarations without a body.
    pub fn functionRange(context: RuleRun, function_index: usize) ?FunctionRange {
        var parameters_start = function_index + 1;
        while (parameters_start < context.tokens.len and context.tokens[parameters_start].tag != .l_paren) : (parameters_start += 1) {}
        if (parameters_start >= context.tokens.len) return null;
        const parameters_end = context.matchingToken(parameters_start, .l_paren, .r_paren) orelse return null;
        var body_start = parameters_end + 1;
        while (body_start < context.tokens.len and context.tokens[body_start].tag != .l_brace and
            context.tokens[body_start].tag != .semicolon) : (body_start += 1)
        {}
        if (body_start >= context.tokens.len or context.tokens[body_start].tag != .l_brace) return null;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse return null;
        return .{ .parameters_start = parameters_start, .parameters_end = parameters_end, .body_start = body_start, .body_end = body_end };
    }

    /// Whether the parameter `parameter_name` in `(start, end)` is declared
    /// with a type whose spelling contains the identifiers of `type_path` in order.
    pub fn parameterNamesTypePath(
        context: RuleRun,
        parameter_name: []const u8,
        type_path: []const []const u8,
        start: usize,
        end: usize,
    ) bool {
        for (context.tokens[start + 1 .. end], start + 1..) |token, name_index| {
            if (token.tag != .identifier or !context.tokenIs(name_index, parameter_name) or
                name_index + 1 >= end or context.tokens[name_index + 1].tag != .colon) continue;
            var segment_end = name_index + 2;
            while (segment_end < end and context.tokens[segment_end].tag != .comma) : (segment_end += 1) {}
            var matched: usize = 0;
            for (context.tokens[name_index + 2 .. segment_end], name_index + 2..) |type_token, index| {
                if (type_token.tag != .identifier or matched >= type_path.len or !context.tokenIs(index, type_path[matched])) continue;
                matched += 1;
            }
            return matched == type_path.len;
        }
        return false;
    }

    /// Whether the token is the `fn` of a named function declaration.
    pub fn isNamedFunction(context: RuleRun, fn_index: usize) bool {
        return context.tokens[fn_index].tag == .keyword_fn and fn_index + 2 < context.tokens.len and
            context.tokens[fn_index + 1].tag == .identifier and context.tokens[fn_index + 2].tag == .l_paren;
    }

    /// Start of the dotted identifier path that ends right before `end`.
    pub fn pathStartBefore(context: RuleRun, end: usize) ?usize {
        var start = end;
        var expect_identifier = true;
        while (start > 0) {
            const previous = context.tokens[start - 1];
            if (expect_identifier and previous.tag == .identifier) {
                start -= 1;
                expect_identifier = false;
            } else if (!expect_identifier and previous.tag == .period) {
                start -= 1;
                expect_identifier = true;
            } else break;
        }
        return if (expect_identifier) null else start;
    }

    /// Whether two token ranges spell the same dotted identifier path.
    pub fn dottedPathsEqual(context: RuleRun, left_start: usize, left_end: usize, right_start: usize, right_end: usize) bool {
        if (left_end - left_start != right_end - right_start or left_start >= left_end) return false;
        for (context.tokens[left_start..left_end], context.tokens[right_start..right_end], 0..) |left, right, offset| {
            const expected: std.zig.Token.Tag = if (offset % 2 == 0) .identifier else .period;
            if (left.tag != expected or right.tag != expected or
                !std.mem.eql(u8, context.source[left.loc.start..left.loc.end], context.source[right.loc.start..right.loc.end])) return false;
        }
        return (left_end - left_start) % 2 == 1;
    }

    /// The `{` opening a `while` body whose condition closes at `condition_end`,
    /// after any payload capture and continue expression.
    pub fn whileBodyOpening(context: RuleRun, condition_end: usize) ?usize {
        var cursor = condition_end + 1;
        if (cursor >= context.tokens.len) return null;
        if (context.tokens[cursor].tag == .pipe) {
            cursor = tokens_util.nextTagBefore(context.tokens, cursor + 1, .pipe, .semicolon) orelse return null;
            cursor += 1;
        }
        if (cursor < context.tokens.len and context.tokens[cursor].tag == .colon) {
            cursor += 1;
            if (cursor >= context.tokens.len or context.tokens[cursor].tag != .l_paren) return null;
            cursor = (context.matchingToken(cursor, .l_paren, .r_paren) orelse return null) + 1;
        }
        return if (cursor < context.tokens.len and context.tokens[cursor].tag == .l_brace) cursor else null;
    }

    pub fn argumentSource(context: RuleRun, range: tokens_util.Range) []const u8 {
        return tokens_util.rangeSource(context.source, context.tokens, range);
    }
};

/// Parsed inputs of one source for building a `RuleRun`: the syntax tree and
/// scope index the pipeline driver shares between rules.
pub const Syntax = struct {
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    tree: std.zig.Ast,
    scopes: syntax_scope.Index,

    /// Borrows `tokens`, which must outlive the result.
    pub fn init(allocator: std.mem.Allocator, source: [:0]const u8, tokens: []const std.zig.Token) !Syntax {
        var tree = try std.zig.Ast.parse(allocator, source, .{ .mode = .zig });
        errdefer tree.deinit(allocator);
        return .{
            .source = source,
            .tokens = tokens,
            .tree = tree,
            .scopes = try syntax_scope.Index.init(allocator, source, tokens),
        };
    }

    pub fn deinit(syntax: *Syntax, allocator: std.mem.Allocator) void {
        syntax.scopes.deinit();
        syntax.tree.deinit(allocator);
    }

    pub fn ruleRun(
        syntax: *const Syntax,
        allocator: std.mem.Allocator,
        configuration: types.Configuration,
        found: *std.ArrayList(types.Finding),
    ) RuleRun {
        return .{
            .allocator = allocator,
            .source = syntax.source,
            .tokens = syntax.tokens,
            .configuration = configuration,
            .findings = found,
            .tree = &syntax.tree,
            .scopes = &syntax.scopes,
        };
    }
};

pub fn tokenRefersToBinding(
    source: []const u8,
    tokens: []const std.zig.Token,
    index: usize,
    name: []const u8,
) bool {
    const token = tokens[index];
    if (token.tag != .identifier or !std.mem.eql(u8, source[token.loc.start..token.loc.end], name)) return false;
    return index == 0 or tokens[index - 1].tag != .period;
}

const test_source: [:0]const u8 = "fn f(a: u8) u8 { if (a > 0) { return a; } return a; }";

const Fixture = struct {
    tokens: []const std.zig.Token,
    syntax: Syntax,
    found: std.ArrayList(types.Finding) = .empty,

    fn init(allocator: std.mem.Allocator, source: [:0]const u8) !Fixture {
        const tokens = try tokens_util.tokenize(allocator, source);
        errdefer allocator.free(tokens);
        return .{ .tokens = tokens, .syntax = try Syntax.init(allocator, source, tokens) };
    }

    fn run(fixture: *Fixture, allocator: std.mem.Allocator) RuleRun {
        return fixture.syntax.ruleRun(allocator, types.Configuration.defaults(), &fixture.found);
    }
};

test "emit records findings and drops those whose level is off" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator(), test_source);
    const context = fixture.run(arena.allocator());
    try context.emit(.{ .rule = .never_mutated_var, .level = .off, .span = .{ .start = 0, .end = 1 }, .message = "off" });
    try std.testing.expectEqual(@as(usize, 0), fixture.found.items.len);
    try context.emit(.{ .rule = .never_mutated_var, .level = .warning, .span = .{ .start = 0, .end = 1 }, .message = "on" });
    try std.testing.expectEqual(@as(usize, 1), fixture.found.items.len);
    try std.testing.expectEqualStrings("on", fixture.found.items[0].message);
}

test "level reads the configured level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator(), test_source);
    var context = fixture.run(arena.allocator());
    context.configuration.levels[@backingInt(types.Rule.never_mutated_var)] = .@"error";
    try std.testing.expectEqual(types.Level.@"error", context.level(.never_mutated_var));
}

test "single fixes carry one edit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator(), test_source);
    const context = fixture.run(arena.allocator());
    const fixes = try context.singleFix(.{
        .title = "Rename",
        .span = .{ .start = 3, .end = 4 },
        .replacement = "g",
        .preferred = true,
    });
    try std.testing.expectEqual(@as(usize, 1), fixes.len);
    try std.testing.expectEqual(@as(usize, 1), fixes[0].edits.len);
    try std.testing.expectEqualStrings("g", fixes[0].edits[0].replacement);
    try std.testing.expect(fixes[0].preferred and !fixes[0].fix_all);
}

test "token helpers read text and match delimiters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator(), test_source);
    const context = fixture.run(arena.allocator());
    const tokens = context.tokens;
    try std.testing.expectEqualStrings("fn", context.tokenText(0));
    try std.testing.expect(context.tokenIs(1, "f"));
    try std.testing.expect(!context.tokenIs(1, "g"));
    try std.testing.expect(!context.tokenIs(tokens.len, "f"));
    // `(a: u8)` is tokens 2..6, the outer body brace opens at token 8.
    try std.testing.expectEqual(@as(?usize, 6), context.matchingToken(2, .l_paren, .r_paren));
    const body_open = 8;
    try std.testing.expectEqual(std.zig.Token.Tag.l_brace, tokens[body_open].tag);
    try std.testing.expectEqual(@as(?usize, tokens.len - 2), context.matchingToken(body_open, .l_brace, .r_brace));
}

test "statement and scope helpers find enclosing structure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator(), test_source);
    const context = fixture.run(arena.allocator());
    const tokens = context.tokens;
    var inner_return: usize = 0;
    for (tokens, 0..) |token, index| {
        if (token.tag == .keyword_return) {
            inner_return = index;
            break;
        }
    }
    const semicolon = context.statementEnd(inner_return).?;
    try std.testing.expectEqual(std.zig.Token.Tag.semicolon, tokens[semicolon].tag);
    const opening = context.enclosingOpeningBrace(inner_return).?;
    try std.testing.expectEqual(std.zig.Token.Tag.l_brace, tokens[opening].tag);
    try std.testing.expectEqual(semicolon + 1, context.enclosingScopeEnd(inner_return).?);
    try std.testing.expectEqual(@as(?usize, null), context.enclosingOpeningBrace(0));
    try std.testing.expectEqual(@as(?usize, null), context.enclosingScopeEnd(0));
}

test "refersToBinding skips member names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator(), "const x = x + y.x;");
    const context = fixture.run(arena.allocator());
    try std.testing.expect(context.refersToBinding(3, "x"));
    try std.testing.expect(!context.refersToBinding(3, "y"));
    try std.testing.expect(!context.refersToBinding(7, "x"));
}

test "run hands the rule a tree and scope index of its source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator(), test_source);
    const context = fixture.run(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), context.tree.rootDecls().len);
    try std.testing.expect(context.scopes.findBinding(1) != null);
}
