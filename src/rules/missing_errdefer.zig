const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.missing_errdefer);
    if (level == .off) return;

    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or
            declaration_index + 4 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const acquisition = allocatingAcquisition(context, declaration_index, declaration_end) orelse continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const binding_name = context.tokenText(declaration_index + 1);
        const receiver = context.source[context.tokens[acquisition.receiver_start].loc.start..context.tokens[acquisition.receiver_end].loc.end];
        const method = context.tokenText(acquisition.method_index);
        if (std.ascii.indexOfIgnoreCase(receiver, "arena") != null) continue;
        if (declarationLooksArenaBacked(context, context.tokenText(acquisition.receiver_start))) continue;
        if (scopeReleasesBinding(context, scope_opening, scope_end, binding_name)) continue;
        const fallible_index = fallibleBeforeBindingUse(context, declaration_end + 1, scope_end, binding_name) orelse continue;

        const release: []const u8 = if (std.mem.eql(u8, method, "create")) "destroy" else "free";
        const indent = lineIndent(context.source, context.tokens[declaration_index].loc.start);
        const semicolon_end = context.tokens[declaration_end].loc.end;
        const edits = try context.allocator.alloc(types.Edit, 1);
        if (std.mem.indexOfScalarPos(u8, context.source, semicolon_end, '\n')) |line_break| {
            edits[0] = .{
                .span = .{ .start = line_break + 1, .end = line_break + 1 },
                .replacement = try std.fmt.allocPrint(context.allocator, "{s}errdefer {s}.{s}({s});\n", .{ indent, receiver, release, binding_name }),
            };
        } else {
            edits[0] = .{
                .span = .{ .start = semicolon_end, .end = semicolon_end },
                .replacement = try std.fmt.allocPrint(context.allocator, "\n{s}errdefer {s}.{s}({s});", .{ indent, receiver, release, binding_name }),
            };
        }
        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = "Add an errdefer release after the acquisition",
            .kind = .quickfix,
            .edits = edits,
            .preferred = true,
        };
        const related = try context.allocator.alloc(types.RelatedSpan, 1);
        related[0] = .{
            .span = context.tokens[fallible_index].loc,
            .message = try context.allocator.dupe(u8, "this fallible operation leaks the allocation when it fails"),
        };
        try context.emit(.{
            .rule = .missing_errdefer,
            .level = level,
            .span = context.tokens[declaration_index + 1].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "allocation '{s}' from '{s}.{s}' has no errdefer release before the next fallible operation, so the error path leaks it",
                .{ binding_name, receiver, method },
            ),
            .related = related,
            .fixes = fixes,
        });
    }
}

const Acquisition = struct {
    receiver_start: usize,
    receiver_end: usize,
    method_index: usize,
};

fn allocatingAcquisition(context: RuleRun, declaration_index: usize, declaration_end: usize) ?Acquisition {
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    var equal_index: ?usize = null;
    var index = declaration_index + 2;
    while (index < declaration_end) : (index += 1) {
        switch (context.tokens[index].tag) {
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .l_bracket => bracket_depth += 1,
            .r_bracket => bracket_depth -|= 1,
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            .equal => if (parenthesis_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
                equal_index = index;
            },
            else => {},
        }
        if (equal_index != null) break;
    }
    const equal = equal_index orelse return null;
    if (equal + 4 >= declaration_end or context.tokens[equal + 1].tag != .keyword_try or
        context.tokens[equal + 2].tag != .identifier) return null;
    var path_end = equal + 2;
    while (path_end + 2 < declaration_end and context.tokens[path_end + 1].tag == .period and
        context.tokens[path_end + 2].tag == .identifier) path_end += 2;
    if (path_end == equal + 2 or path_end + 1 >= declaration_end or
        context.tokens[path_end + 1].tag != .l_paren) return null;
    const call_close = context.matchingToken(path_end + 1, .l_paren, .r_paren) orelse return null;
    if (call_close + 1 != declaration_end) return null;
    if (!isAllocatingMethod(context.tokenText(path_end))) return null;
    return .{ .receiver_start = equal + 2, .receiver_end = path_end - 2, .method_index = path_end };
}

fn isAllocatingMethod(name: []const u8) bool {
    const allocating_methods = [_][]const u8{ "alloc", "allocSentinel", "alignedAlloc", "dupe", "dupeZ", "create" };
    for (allocating_methods) |method| if (std.mem.eql(u8, name, method)) return true;
    return false;
}

fn declarationLooksArenaBacked(context: RuleRun, root_name: []const u8) bool {
    for (context.tokens, 0..) |token, index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or
            index + 1 >= context.tokens.len or
            !context.tokenIs(index + 1, root_name)) continue;
        const end = context.statementEnd(index) orelse continue;
        const declaration = context.source[token.loc.start..context.tokens[end].loc.end];
        if (std.mem.indexOf(u8, declaration, "ArenaAllocator") != null or
            std.mem.indexOf(u8, declaration, "FixedBufferAllocator") != null or
            std.mem.indexOf(u8, declaration, ".allocator()") != null) return true;
    }
    return false;
}

fn scopeReleasesBinding(context: RuleRun, scope_opening: usize, scope_end: usize, binding: []const u8) bool {
    var index = scope_opening + 1;
    while (index < scope_end) : (index += 1) {
        const tag = context.tokens[index].tag;
        if (tag != .keyword_defer and tag != .keyword_errdefer) continue;
        var body_start = index + 1;
        if (body_start < scope_end and context.tokens[body_start].tag == .pipe) {
            body_start += 1;
            while (body_start < scope_end and context.tokens[body_start].tag != .pipe) body_start += 1;
            body_start += 1;
        }
        if (body_start >= scope_end) return true;
        const body_end = if (context.tokens[body_start].tag == .l_brace)
            context.matchingToken(body_start, .l_brace, .r_brace) orelse return true
        else
            context.statementEnd(body_start) orelse return true;
        for (context.tokens[body_start..@min(body_end + 1, scope_end)], body_start..) |body_token, body_index| {
            if (body_token.tag == .identifier and context.tokenIs(body_index, binding)) return true;
        }
        index = body_end;
    }
    return false;
}

fn fallibleBeforeBindingUse(context: RuleRun, start: usize, scope_end: usize, binding: []const u8) ?usize {
    var cursor = start;
    while (cursor < scope_end) {
        const end = context.statementEnd(cursor) orelse return null;
        if (end >= scope_end) return null;
        var fallible_index: ?usize = null;
        for (context.tokens[cursor .. end + 1], cursor..) |chunk_token, chunk_index| {
            switch (chunk_token.tag) {
                .keyword_return => return null,
                .keyword_try => if (fallible_index == null) {
                    fallible_index = chunk_index;
                },
                .identifier => if (context.tokenIs(chunk_index, binding)) return null,
                else => {},
            }
        }
        if (fallible_index) |found| return found;
        cursor = end + 1;
    }
    return null;
}

fn lineIndent(source: []const u8, offset: usize) []const u8 {
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..offset], '\n')) |newline| newline + 1 else 0;
    var end = line_start;
    while (end < source.len and (source[end] == ' ' or source[end] == '\t')) end += 1;
    return source[line_start..end];
}

test "allocation followed by another fallible operation without errdefer leaks on the error path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn build(allocator: std.mem.Allocator) !void {\n" ++
        "    const buffer = try allocator.alloc(u8, 4);\n" ++
        "    const node = try allocator.create(u32);\n" ++
        "    try fill(buffer, node);\n" ++
        "}\n" ++
        "fn init(allocator: std.mem.Allocator) !void {\n" ++
        "    const node = try allocator.create(u32);\n" ++
        "    const extra = try allocator.alloc(u8, 2);\n" ++
        "    use(node, extra);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "'buffer'") != null);
    try std.testing.expectEqualStrings("    errdefer allocator.free(buffer);\n", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expect(std.mem.indexOf(u8, findings[1].message, "'node'") != null);
    try std.testing.expectEqualStrings("    errdefer allocator.destroy(node);\n", findings[1].fixes[0].edits[0].replacement);
    try std.testing.expect(!findings[0].fixes[0].fix_all);
}

test "released transferred arena-backed and final allocations stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn released(allocator: std.mem.Allocator) !void {\n" ++
        "    const buffer = try allocator.alloc(u8, 4);\n" ++
        "    errdefer allocator.free(buffer);\n" ++
        "    const extra = try allocator.alloc(u8, 4);\n" ++
        "    defer allocator.free(extra);\n" ++
        "    try flush(buffer, extra);\n" ++
        "}\n" ++
        "fn stored(gpa: std.mem.Allocator, sink: *Sink) !void {\n" ++
        "    const owned = try gpa.dupe(u8, \"name\");\n" ++
        "    sink.value = owned;\n" ++
        "    try sink.commit();\n" ++
        "}\n" ++
        "fn scratch(gpa: std.mem.Allocator) !void {\n" ++
        "    var arena_state = std.heap.ArenaAllocator.init(gpa);\n" ++
        "    defer arena_state.deinit();\n" ++
        "    const scratch_allocator = arena_state.allocator();\n" ++
        "    const scratch_bytes = try scratch_allocator.alloc(u8, 4);\n" ++
        "    const more = try scratch_allocator.alloc(u8, 4);\n" ++
        "    try consume(scratch_bytes, more);\n" ++
        "}\n" ++
        "fn last(allocator: std.mem.Allocator) ![]u8 {\n" ++
        "    const buffer = try allocator.alloc(u8, 4);\n" ++
        "    return buffer;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "missing errdefer diagnostics honor suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn build(allocator: std.mem.Allocator) !void {\n" ++
        "    // zig-analyzer: disable-next-line missing-errdefer\n" ++
        "    const buffer = try allocator.alloc(u8, 4);\n" ++
        "    const node = try allocator.create(u32);\n" ++
        "    try fill(buffer, node);\n" ++
        "}\n";
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

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return try tokens.toOwnedSlice(allocator);
        try tokens.append(allocator, token);
    }
}
