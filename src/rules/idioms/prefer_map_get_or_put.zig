const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{
    .prefer_map_get_or_put,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_map_get_or_put);
    if (level == .off) return;

    for (context.tokens, 0..) |token, if_index| {
        if (token.tag != .keyword_if or if_index + 1 >= context.tokens.len or
            context.tokens[if_index + 1].tag != .l_paren) continue;

        const cond_end = context.matchingToken(if_index + 1, .l_paren, .r_paren) orelse continue;
        if (cond_end + 1 >= context.tokens.len) continue;

        // Pattern 1: if (!map.contains(key)) or if (!map.contains(allocator, key))
        // Pattern 2: if (map.get(key) == null) or if (null == map.get(key))
        const check = parseMapCondition(context, if_index + 2, cond_end) orelse continue;

        // Look for map.put(key, ...) inside the if body
        const body_start = cond_end + 1;
        const body_end = if (context.tokens[body_start].tag == .l_brace)
            context.matchingToken(body_start, .l_brace, .r_brace) orelse continue
        else
            findStatementEnd(context, body_start);

        if (findPutCall(context, body_start, body_end, check.map_name, check.key_name)) |put_token_index| {
            const method_name = if (check.kind == .contains) "contains" else "get";
            try context.emit(.{
                .rule = .prefer_map_get_or_put,
                .level = level,
                .span = context.tokens[put_token_index].loc,
                .message = try context.allocator.print(
                    "'{s}.{s}' followed by '{s}.put' repeats key hashing and bucket probing; use '{s}.getOrPut'",
                    .{ check.map_name, method_name, check.map_name, check.map_name },
                ),
            });
        }
    }
}

const ConditionKind = enum { contains, get_null };

const MapCheck = struct {
    kind: ConditionKind,
    map_name: []const u8,
    key_name: []const u8,
};

fn parseMapCondition(context: RuleRun, start: usize, end: usize) ?MapCheck {
    if (start >= end) return null;

    // Pattern 1: !map.contains(...)
    if (context.tokens[start].tag == .bang and start + 4 < end) {
        const after_bang = start + 1;
        if (context.tokens[after_bang].tag == .identifier and
            context.tokens[after_bang + 1].tag == .period and
            context.tokenIs(after_bang + 2, "contains") and
            context.tokens[after_bang + 3].tag == .l_paren)
        {
            const r_paren = context.matchingToken(after_bang + 3, .l_paren, .r_paren) orelse return null;
            if (r_paren != end - 1) return null;
            const map_name = context.tokenText(after_bang);
            const key_name = extractMapKeyArgument(context, after_bang + 4, r_paren) orelse return null;
            return .{ .kind = .contains, .map_name = map_name, .key_name = key_name };
        }
    }

    // Pattern 2a: map.get(...) == null
    if (end >= start + 5 and context.tokens[end - 2].tag == .equal_equal and context.tokenIs(end - 1, "null")) {
        const lhs_end = end - 2;
        if (context.tokens[start].tag == .identifier and
            context.tokens[start + 1].tag == .period and
            context.tokenIs(start + 2, "get") and
            context.tokens[start + 3].tag == .l_paren)
        {
            const r_paren = context.matchingToken(start + 3, .l_paren, .r_paren) orelse return null;
            if (r_paren + 1 != lhs_end) return null;
            const map_name = context.tokenText(start);
            const key_name = extractMapKeyArgument(context, start + 4, r_paren) orelse return null;
            return .{ .kind = .get_null, .map_name = map_name, .key_name = key_name };
        }
    }

    // Pattern 2b: null == map.get(...)
    if (start + 5 < end and context.tokenIs(start, "null") and context.tokens[start + 1].tag == .equal_equal) {
        const rhs_start = start + 2;
        if (context.tokens[rhs_start].tag == .identifier and
            context.tokens[rhs_start + 1].tag == .period and
            context.tokenIs(rhs_start + 2, "get") and
            context.tokens[rhs_start + 3].tag == .l_paren)
        {
            const r_paren = context.matchingToken(rhs_start + 3, .l_paren, .r_paren) orelse return null;
            if (r_paren != end - 1) return null;
            const map_name = context.tokenText(rhs_start);
            const key_name = extractMapKeyArgument(context, rhs_start + 4, r_paren) orelse return null;
            return .{ .kind = .get_null, .map_name = map_name, .key_name = key_name };
        }
    }

    return null;
}

fn extractMapKeyArgument(context: RuleRun, args_start: usize, args_end: usize) ?[]const u8 {
    if (args_start >= args_end) return null;

    // Check if there is a comma (for unmanaged maps: map.contains(allocator, key))
    var depth: usize = 0;
    var comma_idx: ?usize = null;
    for (context.tokens[args_start..args_end], args_start..) |token, i| {
        switch (token.tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            .comma => if (depth == 0) {
                comma_idx = i;
            },
            else => {},
        }
    }

    const key_start = if (comma_idx) |c| c + 1 else args_start;
    if (key_start >= args_end) return null;

    return std.mem.trim(u8, context.source[context.tokens[key_start].loc.start..context.tokens[args_end - 1].loc.end], " \t\r\n");
}

fn findPutCall(context: RuleRun, start: usize, end: usize, map_name: []const u8, key_name: []const u8) ?usize {
    var i = start;
    while (i + 4 < end) : (i += 1) {
        if (!context.tokenIs(i, map_name) or
            context.tokens[i + 1].tag != .period or
            !context.tokenIs(i + 2, "put") or
            context.tokens[i + 3].tag != .l_paren) continue;

        const r_paren = context.matchingToken(i + 3, .l_paren, .r_paren) orelse continue;
        if (r_paren > end) continue;

        // Check the key argument in map.put([allocator, ]key, val)
        const put_key = extractPutKeyArgument(context, i + 4, r_paren) orelse continue;
        if (std.mem.eql(u8, put_key, key_name)) {
            return i + 2; // return index of 'put' token
        }
    }
    return null;
}

fn extractPutKeyArgument(context: RuleRun, args_start: usize, args_end: usize) ?[]const u8 {
    var commas: [2]usize = undefined;
    var comma_count: usize = 0;
    var depth: usize = 0;

    for (context.tokens[args_start..args_end], args_start..) |token, i| {
        switch (token.tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            .comma => if (depth == 0) {
                if (comma_count < 2) commas[comma_count] = i;
                comma_count += 1;
            },
            else => {},
        }
    }

    if (comma_count == 1) {
        // map.put(key, val)
        const key_expr = std.mem.trim(u8, context.source[context.tokens[args_start].loc.start..context.tokens[commas[0] - 1].loc.end], " \t\r\n");
        return key_expr;
    } else if (comma_count == 2) {
        // map.put(allocator, key, val)
        const key_expr = std.mem.trim(u8, context.source[context.tokens[commas[0] + 1].loc.start..context.tokens[commas[1] - 1].loc.end], " \t\r\n");
        return key_expr;
    }

    return null;
}

fn findStatementEnd(context: RuleRun, start: usize) usize {
    var i = start;
    while (i < context.tokens.len) : (i += 1) {
        if (context.tokens[i].tag == .semicolon) return i + 1;
    }
    return context.tokens.len;
}

test "prefer map get or put detects !map.contains then map.put" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\fn cache(map: *std.AutoHashMap(u32, u32), key: u32, val: u32) !void {
        \\    if (!map.contains(key)) {
        \\        try map.put(key, val);
        \\    }
        \\}
    ;

    const findings = try support.findings(arena.allocator(), run, source, testConfiguration());

    try std.testing.expectEqual(1, findings.len);
    try std.testing.expectEqual(types.Rule.prefer_map_get_or_put, findings[0].rule);
    try std.testing.expect(std.mem.find(u8, findings[0].message, "getOrPut") != null);
}

test "prefer map get or put detects map.get == null then map.put" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\fn cache(map: *std.StringHashMap(u32), key: []const u8, val: u32) !void {
        \\    if (map.get(key) == null) try map.put(key, val);
        \\}
    ;

    const findings = try support.findings(arena.allocator(), run, source, testConfiguration());

    try std.testing.expectEqual(1, findings.len);
    try std.testing.expectEqual(types.Rule.prefer_map_get_or_put, findings[0].rule);
}

test "prefer map get or put detects unmanaged map with allocator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\fn cache(map: *std.AutoHashMapUnmanaged(u32, u32), gpa: std.mem.Allocator, key: u32, val: u32) !void {
        \\    if (!map.contains(key)) {
        \\        try map.put(gpa, key, val);
        \\    }
        \\}
    ;

    const findings = try support.findings(arena.allocator(), run, source, testConfiguration());

    try std.testing.expectEqual(1, findings.len);
    try std.testing.expectEqual(types.Rule.prefer_map_get_or_put, findings[0].rule);
}

test "prefer map get or put ignores distinct keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\fn cache(map: *std.AutoHashMap(u32, u32), key1: u32, key2: u32, val: u32) !void {
        \\    if (!map.contains(key1)) {
        \\        try map.put(key2, val);
        \\    }
        \\}
    ;

    const findings = try support.findings(arena.allocator(), run, source, testConfiguration());

    try std.testing.expectEqual(0, findings.len);
}

fn testConfiguration() types.Configuration {
    const configuration = support.only(&.{.prefer_map_get_or_put}, .warning);
    return configuration;
}
