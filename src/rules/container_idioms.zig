const std = @import("std");
const syntax_scope = @import("../syntax_scope.zig");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    try findMembershipLookups(context);
    try findLastElementIndexing(context);
    try findGuardedDiscardedPops(context);
}

fn findMembershipLookups(context: RuleRun) !void {
    const level = context.level(.prefer_map_contains);
    if (level == .off) return;

    for (context.tokens, 0..) |token, get_index| {
        if (token.tag != .identifier or !context.tokenIs(get_index, "get") or get_index < 2 or
            context.tokens[get_index - 1].tag != .period or context.tokens[get_index - 2].tag != .identifier or
            get_index + 1 >= context.tokens.len or context.tokens[get_index + 1].tag != .l_paren) continue;
        const call_end = context.matchingToken(get_index + 1, .l_paren, .r_paren) orelse continue;
        if (call_end + 2 >= context.tokens.len or
            (context.tokens[call_end + 1].tag != .equal_equal and context.tokens[call_end + 1].tag != .bang_equal) or
            !context.tokenIs(call_end + 2, "null")) continue;
        if (!bindingHasStandardMapType(context, get_index - 2)) continue;
        const expression = context.source[context.tokens[get_index - 2].loc.start..context.tokens[call_end + 2].loc.end];
        if (std.mem.indexOf(u8, expression, "//") != null or std.mem.indexOf(u8, expression, "/*") != null) continue;

        const receiver = context.tokenText(get_index - 2);
        const arguments = context.source[context.tokens[get_index + 1].loc.end..context.tokens[call_end].loc.start];
        const replacement = if (context.tokens[call_end + 1].tag == .bang_equal)
            try std.fmt.allocPrint(context.allocator, "{s}.contains({s})", .{ receiver, arguments })
        else
            try std.fmt.allocPrint(context.allocator, "!{s}.contains({s})", .{ receiver, arguments });
        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{
            .span = .{ .start = context.tokens[get_index - 2].loc.start, .end = context.tokens[call_end + 2].loc.end },
            .replacement = replacement,
        };
        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = "Use the map membership operation",
            .kind = .refactor_rewrite,
            .edits = edits,
            .preferred = true,
            .fix_all = true,
        };
        try context.emit(.{
            .rule = .prefer_map_contains,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(context.allocator, "'{s}.get' is used only to test key membership; use '{s}.contains'", .{ receiver, receiver }),
            .fixes = fixes,
        });
    }
}

fn findLastElementIndexing(context: RuleRun) !void {
    const level = context.level(.prefer_array_list_last);
    if (level == .off) return;

    for (context.tokens, 0..) |token, receiver_index| {
        if (token.tag != .identifier or receiver_index + 11 >= context.tokens.len or
            context.tokens[receiver_index + 1].tag != .period or !context.tokenIs(receiver_index + 2, "items") or
            context.tokens[receiver_index + 3].tag != .l_bracket or
            !context.tokenIs(receiver_index + 4, context.tokenText(receiver_index)) or
            context.tokens[receiver_index + 5].tag != .period or !context.tokenIs(receiver_index + 6, "items") or
            context.tokens[receiver_index + 7].tag != .period or !context.tokenIs(receiver_index + 8, "len") or
            context.tokens[receiver_index + 9].tag != .minus or !context.tokenIs(receiver_index + 10, "1") or
            context.tokens[receiver_index + 11].tag != .r_bracket) continue;
        if (!bindingHasStandardArrayListType(context, receiver_index)) continue;

        const receiver = context.tokenText(receiver_index);
        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{
            .span = .{ .start = token.loc.start, .end = context.tokens[receiver_index + 11].loc.end },
            .replacement = try std.fmt.allocPrint(context.allocator, "{s}.getLast()", .{receiver}),
        };
        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = "Use ArrayList.getLast",
            .kind = .refactor_rewrite,
            .edits = edits,
            .preferred = true,
            .fix_all = true,
        };
        try context.emit(.{
            .rule = .prefer_array_list_last,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(context.allocator, "last-element indexing repeats '{s}'; use '{s}.getLast()'", .{ receiver, receiver }),
            .fixes = fixes,
        });
    }
}

fn findGuardedDiscardedPops(context: RuleRun) !void {
    const level = context.level(.prefer_optional_pop);
    if (level == .off) return;

    for (context.tokens, 0..) |token, if_index| {
        if (token.tag != .keyword_if or if_index + 1 >= context.tokens.len or context.tokens[if_index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(if_index + 1, .l_paren, .r_paren) orelse continue;
        const body_start = condition_end + 1;
        if (body_start + 7 >= context.tokens.len or !context.tokenIs(body_start, "_") or
            context.tokens[body_start + 1].tag != .equal or context.tokens[body_start + 2].tag != .identifier or
            context.tokens[body_start + 3].tag != .period or !context.tokenIs(body_start + 4, "pop") or
            context.tokens[body_start + 5].tag != .l_paren or context.tokens[body_start + 6].tag != .r_paren or
            context.tokens[body_start + 7].tag != .semicolon) continue;
        const receiver = context.tokenText(body_start + 2);
        if (!bindingHasStandardArrayListType(context, body_start + 2)) continue;
        const guard = discardedPopGuard(context, if_index + 2, condition_end, receiver) orelse continue;

        const edit_span = if (guard.start == if_index + 2 and guard.end == condition_end)
            std.zig.Token.Loc{ .start = token.loc.start, .end = context.tokens[body_start].loc.start }
        else if (guard.start > if_index + 2 and context.tokens[guard.start - 1].tag == .keyword_and)
            std.zig.Token.Loc{
                .start = context.tokens[guard.start - 2].loc.end,
                .end = if (guard.end == condition_end)
                    context.tokens[condition_end].loc.start
                else
                    context.tokens[guard.end - 1].loc.end,
            }
        else if (guard.end < condition_end and context.tokens[guard.end].tag == .keyword_and)
            std.zig.Token.Loc{ .start = context.tokens[guard.start].loc.start, .end = context.tokens[guard.end + 1].loc.start }
        else
            continue;
        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{ .span = edit_span, .replacement = "" };
        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = "Rely on the optional pop result",
            .kind = .refactor_rewrite,
            .edits = edits,
            .preferred = true,
            .fix_all = true,
        };
        try context.emit(.{
            .rule = .prefer_optional_pop,
            .level = level,
            .span = context.tokens[guard.start].loc,
            .message = try std.fmt.allocPrint(context.allocator, "'{s}.pop()' already returns null when the list is empty; remove the length guard", .{receiver}),
            .fixes = fixes,
        });
    }
}

const TokenRange = struct { start: usize, end: usize };

fn discardedPopGuard(context: RuleRun, start: usize, end: usize, receiver: []const u8) ?TokenRange {
    var depth: usize = 0;
    var index = start;
    while (index + 6 < end) : (index += 1) {
        switch (context.tokens[index].tag) {
            .l_paren, .l_bracket, .l_brace => {
                depth += 1;
                continue;
            },
            .r_paren, .r_bracket, .r_brace => {
                depth -|= 1;
                continue;
            },
            else => {},
        }
        if (depth != 0 or !context.tokenIs(index, receiver) or context.tokens[index + 1].tag != .period or
            !context.tokenIs(index + 2, "items") or context.tokens[index + 3].tag != .period or
            !context.tokenIs(index + 4, "len") or context.tokens[index + 5].tag != .bang_equal or
            !context.tokenIs(index + 6, "0")) continue;
        return .{ .start = index, .end = index + 7 };
    }
    return null;
}

fn bindingHasStandardArrayListType(context: RuleRun, use_index: usize) bool {
    const type_name = explicitBindingType(context, use_index) orelse return false;
    return std.mem.indexOf(u8, type_name, "std.ArrayList(") != null or
        std.mem.indexOf(u8, type_name, "std.ArrayListUnmanaged(") != null;
}

fn bindingHasStandardMapType(context: RuleRun, use_index: usize) bool {
    const type_name = explicitBindingType(context, use_index) orelse return false;
    const standard_maps = [_][]const u8{
        "std.AutoHashMap(",
        "std.AutoHashMapUnmanaged(",
        "std.AutoArrayHashMap(",
        "std.AutoArrayHashMapUnmanaged(",
        "std.StringHashMap(",
        "std.StringHashMapUnmanaged(",
        "std.StringArrayHashMap(",
        "std.StringArrayHashMapUnmanaged(",
        "std.HashMap(",
        "std.HashMapUnmanaged(",
        "std.ArrayHashMap(",
        "std.ArrayHashMapUnmanaged(",
        "std.json.ObjectMap",
    };
    for (standard_maps) |standard_map| if (std.mem.indexOf(u8, type_name, standard_map) != null) return true;
    return false;
}

fn explicitBindingType(context: RuleRun, use_index: usize) ?[]const u8 {
    const binding = syntax_scope.findBinding(context.source, context.tokens, use_index) orelse return null;
    const name_index = binding.token_index;
    if (name_index + 2 >= context.tokens.len or context.tokens[name_index + 1].tag != .colon) return null;
    const type_start = name_index + 2;
    var depth: usize = 0;
    var type_end = type_start;
    while (type_end < context.tokens.len) : (type_end += 1) switch (context.tokens[type_end].tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => {
            if (depth == 0) break;
            depth -= 1;
        },
        .equal, .comma, .semicolon => if (depth == 0) break,
        else => {},
    };
    if (type_end == type_start) return null;
    return std.mem.trim(
        u8,
        context.source[context.tokens[type_start].loc.start..context.tokens[type_end - 1].loc.end],
        " \t\r\n",
    );
}

test "standard container operations replace representation-level idioms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn contains(map: std.StringHashMap(u8), key: []const u8) bool { return map.get(key) != null; }\n" ++
        "fn last(values: std.ArrayList(u8)) u8 { return values.items[values.items.len - 1]; }\n" ++
        "fn close(values: *std.ArrayList(u8), ready: bool) void { if (ready and values.items.len != 0) _ = values.pop(); }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 3), findings.len);
    try std.testing.expectEqualStrings("map.contains(key)", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("values.getLast()", findings[1].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("", findings[2].fixes[0].edits[0].replacement);
    const pop_edit = findings[2].fixes[0].edits[0];
    const fixed = try std.fmt.allocPrint(
        arena.allocator(),
        "{s}{s}{s}",
        .{ source[0..pop_edit.span.start], pop_edit.replacement, source[pop_edit.span.end..] },
    );
    try std.testing.expect(std.mem.indexOf(u8, fixed, "if (ready) _ = values.pop();") != null);
}

test "custom containers and meaningful pop results remain unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn custom(store: Store, key: []const u8) bool { return store.get(key) != null; }\n" ++
        "fn slice(values: []const u8) u8 { return values[values.len - 1]; }\n" ++
        "fn pop(values: *std.ArrayList(u8)) ?u8 { if (values.items.len != 0) return values.pop(); return null; }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "negative membership and sole pop guards keep their behavior" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn missing(map: std.StringHashMap(u8), key: []const u8) bool { return map.get(key) == null; }\n" ++
        "fn close(values: *std.ArrayList(u8)) void { if (values.items.len != 0) _ = values.pop(); }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expectEqualStrings("!map.contains(key)", findings[0].fixes[0].edits[0].replacement);
    const pop_edit = findings[1].fixes[0].edits[0];
    const fixed = try std.fmt.allocPrint(
        arena.allocator(),
        "{s}{s}{s}",
        .{ source[0..pop_edit.span.start], pop_edit.replacement, source[pop_edit.span.end..] },
    );
    try std.testing.expect(std.mem.indexOf(u8, fixed, "{ _ = values.pop(); }") != null);
}

test "container preferences respect source suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn last(values: std.ArrayList(u8)) u8 {\n" ++
        "    // zig-analyzer: disable-next-line prefer-array-list-last\n" ++
        "    return values.items[values.items.len - 1];\n" ++
        "}";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.prefer_map_contains)] = .information;
    configuration.levels[@intFromEnum(types.Rule.prefer_array_list_last)] = .information;
    configuration.levels[@intFromEnum(types.Rule.prefer_optional_pop)] = .information;
    try run(.{
        .allocator = allocator,
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
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
