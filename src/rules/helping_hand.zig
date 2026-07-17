const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    try findRangeLoops(context);
    try findManualSearches(context);
    try findElementFills(context);
    try findElementCopies(context);
    try findStringDispatch(context);
    try findDebugPrints(context);
    try findUnbufferedLoopWrites(context);
    try findArenaShapedScopes(context);
}

fn findRangeLoops(context: RuleRun) !void {
    const level = context.level(.prefer_range_for);
    if (level == .off) return;
    for (context.tokens, 0..) |token, var_index| {
        if (token.tag != .keyword_var or var_index + 5 >= context.tokens.len or context.tokens[var_index + 1].tag != .identifier) continue;
        const declaration_end = context.statementEnd(var_index) orelse continue;
        const equal = findTag(context.tokens, var_index + 2, declaration_end, .equal) orelse continue;
        if (equal + 1 >= declaration_end or !context.tokenIs(equal + 1, "0")) continue;
        const while_index = declaration_end + 1;
        if (while_index + 11 >= context.tokens.len or context.tokens[while_index].tag != .keyword_while or
            context.tokens[while_index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(while_index + 1, .l_paren, .r_paren) orelse continue;
        if (condition_end <= while_index + 4 or !context.tokenIs(while_index + 2, context.tokenText(var_index + 1)) or
            context.tokens[while_index + 3].tag != .angle_bracket_left) continue;
        const continue_open = condition_end + 2;
        if (context.tokens[condition_end + 1].tag != .colon or context.tokens[continue_open].tag != .l_paren) continue;
        const continue_end = context.matchingToken(continue_open, .l_paren, .r_paren) orelse continue;
        if (continue_end != continue_open + 4 or !context.tokenIs(continue_open + 1, context.tokenText(var_index + 1)) or
            context.tokens[continue_open + 2].tag != .plus_equal or !context.tokenIs(continue_open + 3, "1")) continue;
        if (continue_end + 1 >= context.tokens.len or context.tokens[continue_end + 1].tag != .l_brace) continue;
        const body_end = context.matchingToken(continue_end + 1, .l_brace, .r_brace) orelse continue;
        const name = context.tokenText(var_index + 1);
        if (bindingAssigned(context, continue_end + 2, body_end, name)) continue;
        if (condition_end != while_index + 5 or
            (context.tokens[while_index + 4].tag != .identifier and context.tokens[while_index + 4].tag != .number_literal)) continue;
        if (context.tokens[while_index + 4].tag == .identifier and
            bindingAssigned(context, continue_end + 2, body_end, context.tokenText(while_index + 4))) continue;
        const scope_end = context.enclosingScopeEnd(var_index) orelse context.tokens.len;
        if (findIdentifier(context, body_end + 1, scope_end, name) != null) continue;
        const bound = context.source[context.tokens[while_index + 4].loc.start..context.tokens[condition_end - 1].loc.end];
        const replacement = try std.fmt.allocPrint(context.allocator, "for (0..{s}) |{s}| {{", .{ bound, name });
        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{
            .span = .{ .start = token.loc.start, .end = context.tokens[continue_end + 1].loc.end },
            .replacement = replacement,
        };
        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{ .title = "Use a range for loop", .kind = .refactor_rewrite, .edits = edits, .preferred = true, .fix_all = true };
        try context.emit(.{
            .rule = .prefer_range_for,
            .level = level,
            .span = context.tokens[while_index].loc,
            .message = try std.fmt.allocPrint(context.allocator, "counter '{s}' only describes the range 0..{s}; use a range for loop", .{ name, bound }),
            .fixes = fixes,
        });
    }
}

fn findManualSearches(context: RuleRun) !void {
    const level = context.level(.prefer_index_of);
    if (level == .off) return;
    for (context.tokens, 0..) |token, for_index| {
        if (token.tag != .keyword_for or for_index + 7 >= context.tokens.len or context.tokens[for_index + 1].tag != .l_paren) continue;
        const iter_end = context.matchingToken(for_index + 1, .l_paren, .r_paren) orelse continue;
        if (iter_end + 6 >= context.tokens.len or context.tokens[iter_end + 1].tag != .pipe) continue;
        const capture_end = findTag(context.tokens, iter_end + 2, context.tokens.len, .pipe) orelse continue;
        if (capture_end != iter_end + 5 or context.tokens[iter_end + 2].tag != .identifier or
            context.tokens[iter_end + 3].tag != .comma or context.tokens[iter_end + 4].tag != .identifier) continue;
        if (capture_end + 1 >= context.tokens.len or context.tokens[capture_end + 1].tag != .l_brace) continue;
        const body_end = context.matchingToken(capture_end + 1, .l_brace, .r_brace) orelse continue;
        if (!isSimpleSearchBody(
            context,
            capture_end + 2,
            body_end,
            context.tokenText(iter_end + 2),
            context.tokenText(iter_end + 4),
        )) continue;
        const iterable = std.mem.trim(u8, context.source[context.tokens[for_index + 2].loc.start..context.tokens[iter_end - 1].loc.end], " \t\r\n");
        try context.emit(.{
            .rule = .prefer_index_of,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(context.allocator, "manual linear search over '{s}' can state its intent with std.mem.indexOfScalar or std.mem.indexOf", .{iterable}),
        });
    }
}

fn findElementFills(context: RuleRun) !void {
    const level = context.level(.prefer_memset);
    if (level == .off) return;
    for (context.tokens, 0..) |token, for_index| {
        if (token.tag != .keyword_for or for_index + 9 >= context.tokens.len or context.tokens[for_index + 1].tag != .l_paren) continue;
        const iter_end = context.matchingToken(for_index + 1, .l_paren, .r_paren) orelse continue;
        if (iter_end + 4 >= context.tokens.len or context.tokens[iter_end + 1].tag != .pipe) continue;
        const capture_end = findTag(context.tokens, iter_end + 2, context.tokens.len, .pipe) orelse continue;
        const capture_start = iter_end + 2;
        const pointer_capture = context.tokens[capture_start].tag == .asterisk and capture_start + 1 < capture_end;
        const name_index = if (pointer_capture) capture_start + 1 else capture_start;
        if (context.tokens[name_index].tag != .identifier or capture_end + 1 >= context.tokens.len or context.tokens[capture_end + 1].tag != .l_brace) continue;
        const body_end = context.matchingToken(capture_end + 1, .l_brace, .r_brace) orelse continue;
        if (!pointer_capture or body_end != capture_end + 7 or !context.tokenIs(capture_end + 2, context.tokenText(name_index)) or
            context.tokens[capture_end + 3].tag != .period_asterisk or context.tokens[capture_end + 4].tag != .equal or
            context.tokens[body_end - 1].tag != .semicolon) continue;
        const target = std.mem.trim(u8, context.source[context.tokens[for_index + 2].loc.start..context.tokens[iter_end - 1].loc.end], " \t\r\n");
        const value = std.mem.trim(u8, context.source[context.tokens[capture_end + 5].loc.start..context.tokens[body_end - 2].loc.end], " \t\r\n");
        if (findIdentifier(context, capture_end + 5, body_end - 1, context.tokenText(name_index)) != null) continue;
        if (!stableFillValue(context.tokens, capture_end + 5, body_end - 1)) continue;
        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{
            .span = .{ .start = token.loc.start, .end = context.tokens[body_end].loc.end },
            .replacement = try std.fmt.allocPrint(context.allocator, "@memset({s}, {s});", .{ target, value }),
        };
        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{ .title = "Replace the element loop with @memset", .kind = .refactor_rewrite, .edits = edits, .preferred = true, .fix_all = true };
        try context.emit(.{ .rule = .prefer_memset, .level = level, .span = token.loc, .message = "this loop only fills every element with one invariant value; use @memset", .fixes = fixes });
    }
}

fn findElementCopies(context: RuleRun) !void {
    const level = context.level(.prefer_memcpy);
    if (level == .off) return;
    for (context.tokens, 0..) |token, for_index| {
        if (token.tag != .keyword_for or for_index + 16 >= context.tokens.len or context.tokens[for_index + 1].tag != .l_paren) continue;
        const iter_end = context.matchingToken(for_index + 1, .l_paren, .r_paren) orelse continue;
        const range = context.source[context.tokens[for_index + 2].loc.start..context.tokens[iter_end - 1].loc.end];
        if (std.mem.indexOf(u8, range, "0..") == null or std.mem.indexOf(u8, range, ".len") == null) continue;
        if (iter_end + 3 >= context.tokens.len or context.tokens[iter_end + 1].tag != .pipe) continue;
        const capture_end = findTag(context.tokens, iter_end + 2, context.tokens.len, .pipe) orelse continue;
        if (capture_end != iter_end + 3 or capture_end + 1 >= context.tokens.len or context.tokens[capture_end + 1].tag != .l_brace) continue;
        const body_end = context.matchingToken(capture_end + 1, .l_brace, .r_brace) orelse continue;
        const index_name = context.tokenText(iter_end + 2);
        if (body_end != capture_end + 12) continue;
        const body = context.tokens[capture_end + 2 .. body_end];
        if (body[0].tag != .identifier or body[1].tag != .l_bracket or !context.tokenIs(capture_end + 4, index_name) or
            body[3].tag != .r_bracket or body[4].tag != .equal or body[5].tag != .identifier or
            body[6].tag != .l_bracket or !context.tokenIs(capture_end + 9, index_name) or body[8].tag != .r_bracket or body[9].tag != .semicolon) continue;
        const destination = context.tokenText(capture_end + 2);
        const source = context.tokenText(capture_end + 7);
        if (std.mem.eql(u8, destination, source) or !bindingsAreDistinctLocalArrays(context, for_index, destination, source)) continue;
        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{ .span = .{ .start = token.loc.start, .end = context.tokens[body_end].loc.end }, .replacement = try std.fmt.allocPrint(context.allocator, "@memcpy({s}, {s});", .{ destination, source }) };
        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{ .title = "Replace the element loop with @memcpy", .kind = .refactor_rewrite, .edits = edits, .preferred = true, .fix_all = true };
        try context.emit(.{ .rule = .prefer_memcpy, .level = level, .span = token.loc, .message = "this loop only copies corresponding elements from distinct bindings; use @memcpy", .fixes = fixes });
    }
}

fn findStringDispatch(context: RuleRun) !void {
    const level = context.level(.prefer_string_switch);
    if (level == .off) return;
    var first: ?usize = null;
    var subject: ?[]const u8 = null;
    var first_literal: ?[]const u8 = null;
    var second_literal: ?[]const u8 = null;
    var arms: usize = 0;
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, "eql") or index < 4 or index + 6 >= context.tokens.len) continue;
        if (!context.tokenIs(index - 4, "std") or !context.tokenIs(index - 2, "mem") or context.tokens[index + 1].tag != .l_paren or
            !context.tokenIs(index + 2, "u8") or context.tokens[index + 3].tag != .comma) continue;
        const end = context.matchingToken(index + 1, .l_paren, .r_paren) orelse continue;
        const comma = topLevelComma(context.tokens, index + 4, end) orelse continue;
        if (comma + 1 >= end or context.tokens[comma + 1].tag != .string_literal) continue;
        const if_index = precedingIf(context.tokens, index) orelse continue;
        const current_subject = std.mem.trim(u8, context.source[context.tokens[index + 4].loc.start..context.tokens[comma - 1].loc.end], " \t\r\n");
        const literal = context.tokenText(comma + 1);
        const continues_chain = if_index > 0 and context.tokens[if_index - 1].tag == .keyword_else;
        if (subject == null or !continues_chain) {
            subject = current_subject;
            first = index;
            arms = 1;
            first_literal = literal;
            second_literal = null;
        } else if (std.mem.eql(u8, subject.?, current_subject)) {
            arms += 1;
            if (arms == 2) second_literal = literal;
        } else {
            subject = current_subject;
            first = index;
            arms = 1;
            first_literal = literal;
            second_literal = null;
        }
        if (arms != 3) continue;
        if (std.mem.eql(u8, literal, first_literal.?) or std.mem.eql(u8, literal, second_literal.?)) continue;
        try context.emit(.{
            .rule = .prefer_string_switch,
            .level = level,
            .span = context.tokens[first.?].loc,
            .message = try std.fmt.allocPrint(context.allocator, "three or more string comparisons dispatch on '{s}'; use std.meta.stringToEnum or std.StaticStringMap", .{subject.?}),
        });
    }
}

fn findDebugPrints(context: RuleRun) !void {
    const level = context.level(.prefer_log_over_print);
    if (level == .off) return;
    if (std.mem.indexOf(u8, context.source, "pub fn build(") != null) return;
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, "print") or index < 4 or
            !context.tokenIs(index - 4, "std") or !context.tokenIs(index - 2, "debug")) continue;
        if (insideTestBlock(context, index) or insideTestOnlyFunction(context, index)) continue;
        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{ .span = .{ .start = context.tokens[index - 4].loc.start, .end = token.loc.end }, .replacement = "std.log.debug" };
        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{ .title = "Use std.log.debug", .kind = .quickfix, .edits = edits };
        try context.emit(.{ .rule = .prefer_log_over_print, .level = level, .span = token.loc, .message = "std.debug.print is unconditional diagnostic output; use std.log so callers control level and scope", .fixes = fixes });
    }
}

fn findUnbufferedLoopWrites(context: RuleRun) !void {
    const level = context.level(.prefer_buffered_writer);
    if (level == .off) return;
    for (context.tokens, 0..) |token, loop_index| {
        if (token.tag != .keyword_for and token.tag != .keyword_while) continue;
        const opening = findTag(context.tokens, loop_index + 1, @min(loop_index + 24, context.tokens.len), .l_brace) orelse continue;
        const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse continue;
        for (context.tokens[opening + 1 .. closing], opening + 1..) |body_token, index| {
            if (body_token.tag != .identifier or (!context.tokenIs(index, "write") and !context.tokenIs(index, "writeAll") and !context.tokenIs(index, "print")) or
                index < 2 or context.tokens[index - 1].tag != .period or context.tokens[index - 2].tag != .identifier) continue;
            const writer = context.tokenText(index - 2);
            if (!bindingComesFromDirectWriter(context, loop_index, writer)) continue;
            try context.emit(.{
                .rule = .prefer_buffered_writer,
                .level = level,
                .span = body_token.loc,
                .message = try std.fmt.allocPrint(context.allocator, "writer '{s}' performs small unbuffered writes inside a loop; buffer it and flush once", .{writer}),
            });
            break;
        }
    }
}

fn findArenaShapedScopes(context: RuleRun) !void {
    const level = context.level(.prefer_arena);
    if (level == .off) return;
    for (context.tokens, 0..) |token, opening| {
        if (token.tag != .l_brace) continue;
        const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse continue;
        var allocation_count: usize = 0;
        var cleanup_count: usize = 0;
        var allocator_name: ?[]const u8 = null;
        var nested_depth: usize = 0;
        var has_direct_return = false;
        for (context.tokens[opening + 1 .. closing], opening + 1..) |body_token, index| {
            if (body_token.tag == .l_brace) {
                nested_depth += 1;
                continue;
            }
            if (body_token.tag == .r_brace) {
                nested_depth -|= 1;
                continue;
            }
            if (nested_depth != 0) continue;
            if (body_token.tag == .keyword_return) has_direct_return = true;
            if (body_token.tag != .identifier or index + 3 >= closing or context.tokens[index + 1].tag != .period or
                context.tokens[index + 2].tag != .identifier or context.tokens[index + 3].tag != .l_paren) continue;
            const method = context.tokenText(index + 2);
            if (std.mem.eql(u8, method, "alloc") or std.mem.eql(u8, method, "create") or std.mem.eql(u8, method, "dupe")) {
                const candidate = context.tokenText(index);
                if (allocator_name == null) allocator_name = candidate;
                if (std.mem.eql(u8, allocator_name.?, candidate)) allocation_count += 1;
            }
            if ((std.mem.eql(u8, method, "free") or std.mem.eql(u8, method, "destroy")) and
                allocator_name != null and context.tokenIs(index, allocator_name.?) and index > opening + 1 and
                (context.tokens[index - 1].tag == .keyword_defer or context.tokens[index - 1].tag == .keyword_errdefer)) cleanup_count += 1;
        }
        if (allocation_count < 3 or cleanup_count < allocation_count or has_direct_return) continue;
        try context.emit(.{
            .rule = .prefer_arena,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(context.allocator, "scope makes {d} allocations from '{s}' and releases all at exit; an ArenaAllocator can make that lifetime structural", .{ allocation_count, allocator_name.? }),
        });
    }
}

fn insideTestBlock(context: RuleRun, index: usize) bool {
    var test_scopes: [256]bool = @splat(false);
    var depth: usize = 0;
    for (context.tokens[0..index], 0..) |token, token_index| switch (token.tag) {
        .l_brace => {
            if (depth == test_scopes.len) return false;
            const inherited = depth != 0 and test_scopes[depth - 1];
            test_scopes[depth] = inherited or braceBelongsToTest(context.tokens, token_index);
            depth += 1;
        },
        .r_brace => depth -|= 1,
        else => {},
    };
    return depth != 0 and test_scopes[depth - 1];
}

fn insideTestOnlyFunction(context: RuleRun, index: usize) bool {
    const function = functionContaining(context, index) orelse return false;
    var visited: [16]usize = @splat(std.math.maxInt(usize));
    return functionIsTestOnly(context, function, &visited, 0);
}

const FunctionIdentity = struct { name: []const u8, declaration_index: usize };

fn functionContaining(context: RuleRun, index: usize) ?FunctionIdentity {
    var function: ?FunctionIdentity = null;
    for (context.tokens[0..index], 0..) |token, fn_index| {
        if (token.tag != .keyword_fn or fn_index + 1 >= context.tokens.len or context.tokens[fn_index + 1].tag != .identifier) continue;
        const opening = findTag(context.tokens, fn_index + 2, index + 1, .l_brace) orelse continue;
        const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse continue;
        if (index >= closing) continue;
        function = .{ .name = context.tokenText(fn_index + 1), .declaration_index = fn_index + 1 };
    }
    return function;
}

fn functionIsTestOnly(
    context: RuleRun,
    function: FunctionIdentity,
    visited: *[16]usize,
    depth: usize,
) bool {
    if (depth == visited.len) return false;
    for (visited[0..depth]) |declaration_index| if (declaration_index == function.declaration_index) return true;
    visited[depth] = function.declaration_index;
    var saw_caller = false;
    for (context.tokens, 0..) |token, reference| {
        if (reference == function.declaration_index or token.tag != .identifier or !context.tokenIs(reference, function.name) or
            reference + 1 >= context.tokens.len or context.tokens[reference + 1].tag != .l_paren) continue;
        saw_caller = true;
        if (insideTestBlock(context, reference)) continue;
        const caller = functionContaining(context, reference) orelse return false;
        if (!functionIsTestOnly(context, caller, visited, depth + 1)) return false;
    }
    return saw_caller;
}

fn braceBelongsToTest(tokens: []const std.zig.Token, opening: usize) bool {
    var cursor = opening;
    while (cursor > 0 and opening - cursor < 16) {
        cursor -= 1;
        if (tokens[cursor].tag == .keyword_test) return true;
        if (tokens[cursor].tag == .r_brace or tokens[cursor].tag == .semicolon or tokens[cursor].tag == .keyword_fn) return false;
    }
    return false;
}

fn bindingComesFromDirectWriter(context: RuleRun, before: usize, name: []const u8) bool {
    var index: usize = 0;
    while (index + 5 < before) : (index += 1) {
        if ((context.tokens[index].tag != .keyword_const and context.tokens[index].tag != .keyword_var) or
            !context.tokenIs(index + 1, name)) continue;
        const end = context.statementEnd(index) orelse continue;
        const declaration = context.source[context.tokens[index].loc.start..context.tokens[end].loc.end];
        if (std.mem.indexOf(u8, declaration, "stdout()") != null) return true;
        const writer_call = std.mem.indexOf(u8, declaration, ".writer(") orelse continue;
        const receiver_start = std.mem.lastIndexOfAny(u8, declaration[0..writer_call], " =") orelse continue;
        const receiver = std.mem.trim(u8, declaration[receiver_start + 1 .. writer_call], " \t\r\n");
        if (bindingComesFromFileOpen(context, index, receiver)) return true;
    }
    return false;
}

fn bindingComesFromFileOpen(context: RuleRun, before: usize, name: []const u8) bool {
    var index: usize = 0;
    while (index + 4 < before) : (index += 1) {
        if ((context.tokens[index].tag != .keyword_const and context.tokens[index].tag != .keyword_var) or
            !context.tokenIs(index + 1, name)) continue;
        const end = context.statementEnd(index) orelse continue;
        const declaration = context.source[context.tokens[index].loc.start..context.tokens[end].loc.end];
        return std.mem.indexOf(u8, declaration, ".openFile(") != null or
            std.mem.indexOf(u8, declaration, ".createFile(") != null or
            std.mem.indexOf(u8, declaration, ".accept(") != null;
    }
    return false;
}

fn isSimpleSearchBody(context: RuleRun, start: usize, end: usize, element_name: []const u8, index_name: []const u8) bool {
    if (start + 5 >= end or context.tokens[start].tag != .keyword_if or context.tokens[start + 1].tag != .l_paren) return false;
    const condition_end = context.matchingToken(start + 1, .l_paren, .r_paren) orelse return false;
    if (condition_end + 1 >= end or condition_end != start + 5 or context.tokens[start + 3].tag != .equal_equal or
        (!context.tokenIs(start + 2, element_name) and !context.tokenIs(start + 4, element_name)) or
        context.tokens[condition_end + 1].tag == .keyword_else) return false;
    if (context.tokens[condition_end + 1].tag == .keyword_return) {
        return condition_end + 2 < end and context.tokenIs(condition_end + 2, index_name) and
            context.tokens[end - 1].tag == .semicolon and
            findTag(context.tokens, condition_end + 2, end - 1, .semicolon) == null;
    }
    if (context.tokens[condition_end + 1].tag != .l_brace) return false;
    const branch_end = context.matchingToken(condition_end + 1, .l_brace, .r_brace) orelse return false;
    return branch_end + 1 == end and condition_end + 2 < branch_end and
        context.tokens[condition_end + 2].tag == .keyword_return and condition_end + 3 < branch_end and
        context.tokenIs(condition_end + 3, index_name) and context.tokens[branch_end - 1].tag == .semicolon;
}

fn bindingsAreDistinctLocalArrays(context: RuleRun, before: usize, left: []const u8, right: []const u8) bool {
    var saw_left = false;
    var saw_right = false;
    var index: usize = 0;
    while (index + 4 < before) : (index += 1) {
        if ((context.tokens[index].tag != .keyword_const and context.tokens[index].tag != .keyword_var) or
            context.tokens[index + 1].tag != .identifier) continue;
        const name = context.tokenText(index + 1);
        if (!std.mem.eql(u8, name, left) and !std.mem.eql(u8, name, right)) continue;
        const end = context.statementEnd(index) orelse continue;
        const declaration = context.source[context.tokens[index].loc.start..context.tokens[end].loc.end];
        const owns_array = std.mem.indexOf(u8, declaration, "[_]") != null or
            (findTag(context.tokens, index + 2, end, .colon) != null and findTag(context.tokens, index + 2, end, .l_bracket) != null);
        if (!owns_array) continue;
        if (std.mem.eql(u8, name, left)) saw_left = true else saw_right = true;
    }
    return saw_left and saw_right;
}

fn precedingIf(tokens: []const std.zig.Token, index: usize) ?usize {
    var cursor = index;
    while (cursor > 0 and index - cursor < 24) {
        cursor -= 1;
        if (tokens[cursor].tag == .keyword_if) return cursor;
        if (tokens[cursor].tag == .semicolon or tokens[cursor].tag == .l_brace or tokens[cursor].tag == .r_brace) return null;
    }
    return null;
}

fn bindingAssigned(context: RuleRun, start: usize, end: usize, name: []const u8) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name) or index + 1 >= end) continue;
        switch (context.tokens[index + 1].tag) {
            .equal, .plus_equal, .minus_equal, .asterisk_equal, .slash_equal => return true,
            else => {},
        }
    }
    return false;
}

fn stableFillValue(tokens: []const std.zig.Token, start: usize, end: usize) bool {
    if (start >= end) return false;
    for (tokens[start..end]) |token| switch (token.tag) {
        .identifier, .number_literal, .string_literal, .char_literal, .period, .minus, .plus => {},
        else => return false,
    };
    return true;
}

fn findIdentifier(context: RuleRun, start: usize, end: usize, name: []const u8) ?usize {
    for (context.tokens[start..end], start..) |token, index| if (token.tag == .identifier and context.tokenIs(index, name)) return index;
    return null;
}

fn findTag(tokens: []const std.zig.Token, start: usize, end: usize, tag: std.zig.Token.Tag) ?usize {
    for (tokens[start..end], start..) |token, index| if (token.tag == tag) return index;
    return null;
}

fn topLevelComma(tokens: []const std.zig.Token, start: usize, end: usize) ?usize {
    var depth: usize = 0;
    for (tokens[start..end], start..) |token, index| switch (token.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .comma => if (depth == 0) return index,
        else => {},
    };
    return null;
}

test "helping-hand rules recognize their exact manual idioms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn examples(file: anytype, allocator: anytype, self: anytype, needle: u8) !void {\n" ++
        "var i: usize = 0; while (i < count) : (i += 1) { use(names[i]); }\n" ++
        "for (values, 0..) |value, index| { if (value == needle) return index; }\n" ++
        "for (buffer) |*element| { element.* = 0; }\n" ++
        "var dst: [4]u8 = undefined; const src = [_]u8{ 1, 2, 3, 4 }; for (0..dst.len) |j| { dst[j] = src[j]; }\n" ++
        "if (std.mem.eql(u8, cmd, \"start\")) {} else if (std.mem.eql(u8, cmd, \"stop\")) {} else if (std.mem.eql(u8, cmd, \"status\")) {}\n" ++
        "std.debug.print(\"hello\", .{});\n" ++
        "const output = try std.fs.cwd().createFile(\"out\", .{}); const writer = output.writer(); for (values) |value| { try writer.write(value); }\n" ++
        "const a = try allocator.alloc(u8, 1); defer allocator.free(a);\n" ++
        "const b = try allocator.alloc(u8, 1); defer allocator.free(b);\n" ++
        "const c = try allocator.alloc(u8, 1); defer allocator.free(c);\n" ++
        "_ = self; }\n";
    var configuration = types.Configuration.defaults();
    const expected_rules = [_]types.Rule{
        .prefer_range_for,
        .prefer_index_of,
        .prefer_memset,
        .prefer_memcpy,
        .prefer_string_switch,
        .prefer_log_over_print,
        .prefer_buffered_writer,
        .prefer_arena,
    };
    for (expected_rules) |rule| configuration.levels[@intFromEnum(rule)] = .information;
    const found = try findingsFor(arena.allocator(), source, configuration);
    for (expected_rules) |rule| {
        var seen = false;
        for (found) |finding| if (finding.rule == rule) {
            seen = true;
            break;
        };
        if (!seen) std.debug.print("missing helping-hand test finding {s}\n", .{rule.code()});
        try std.testing.expect(seen);
    }
}

test "debug output reachable only from tests remains test output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn printCase() void { std.debug.print(\"case\", .{}); }\n" ++
        "fn verifyCase() void { printCase(); }\n" ++
        "test \"case\" { verifyCase(); }\n";
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.prefer_log_over_print)] = .information;
    const found = try findingsFor(arena.allocator(), source, configuration);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "memset rewrites do not collapse repeated side effects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn fill(buffer: []u8) void { for (buffer) |*element| { element.* = nextValue(); } }";
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.prefer_memset)] = .information;
    const found = try findingsFor(arena.allocator(), source, configuration);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8, configuration: types.Configuration) ![]const types.Finding {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        try tokens.append(allocator, token);
    }
    var found: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = allocator, .source = source, .tokens = tokens.items, .configuration = configuration, .findings = &found });
    return try found.toOwnedSlice(allocator);
}
